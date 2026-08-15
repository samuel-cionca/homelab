"""
Scan Strapi Postgres for internal links and verify they still resolve.

Workflow:
  1. Scan all public tables for hrefs matching DEADLINKS_FRONTEND_URL base(s).
  2. Deduplicate hrefs, then check each once.
  3. CMS pages: GET {DEADLINKS_STRAPI_URL}/api/pages/{path}?locale=...
  4. Product pages (DEADLINKS_PRODUCT_URL_PATTERNS): direct GET to the frontend URL.
  5. Write human-readable logs to DEADLINKS_LOG_PATH / DEADLINKS_DEAD_LOG_PATH; emit JSON to stdout/stderr at end.

Setup:
  cd python-scripts/strapi_v4
  cp .env.template .env
  # Fill in DEADLINKS_* values, then:
  python find-dead-links-in-db.py
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import TextIO
from urllib.parse import quote, urlparse

import psycopg2
import requests
from dotenv import load_dotenv
from requests.auth import HTTPBasicAuth

# Regex for extracting <a href="..."> from HTML stored in DB columns.
HREF_PATTERN = re.compile(r'<a\s+[^>]*href=["\'](.*?)["\'][^>]*>', re.IGNORECASE)


class ConfigError(Exception):
    """Raised when required DEADLINKS_* configuration is missing or invalid."""


@dataclass(frozen=True)
class DeadLinksConfig:
    """Runtime configuration loaded from DEADLINKS_* environment variables."""

    database_name: str
    database_user: str
    database_password: str
    database_host: str
    database_port: str
    strapi_url: str
    strapi_api_key: str | None
    old_urls: tuple[str, ...]
    basic_auth_username: str | None
    basic_auth_password: str | None
    product_url_patterns: tuple[str, ...]
    protected_frontend_hosts: tuple[str, ...]
    log_path: str
    dead_log_path: str
    page_search_timeout: int
    frontend_check_timeout: int
    strapi_check_timeout: int
    content_snippet_len: int
    skip_orphan_components: bool

    def get_frontend_basic_auth(self) -> HTTPBasicAuth | None:
        if self.basic_auth_username and self.basic_auth_password:
            return HTTPBasicAuth(self.basic_auth_username, self.basic_auth_password)
        return None

    @property
    def primary_frontend_url(self) -> str:
        return self.old_urls[0] if self.old_urls else ""

    def page_search_headers(self) -> dict[str, str]:
        return {
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
            "X-Request-Timeout": str(self.page_search_timeout * 1000),
        }


@dataclass(frozen=True)
class AffectedSite:
    slug: str
    id: int | str
    published_at: str | None


@dataclass(frozen=True)
class DeadLinkEntry:
    href: str
    status_code: int
    check_type: str
    affected_sites: tuple[AffectedSite, ...] = ()
    page_search_error: str | None = None


@dataclass(frozen=True)
class RunResult:
    checked: int
    ok_count: int
    dead_count: int
    error_count: int
    dead_links: tuple[DeadLinkEntry, ...]
    warnings: tuple[str, ...] = ()

    def to_json_dict(self, config: DeadLinksConfig) -> dict:
        dead_links = []
        for entry in self.dead_links:
            item = {
                "href": entry.href,
                "status_code": entry.status_code,
                "check_type": entry.check_type,
                "affected_sites": [
                    {
                        "slug": site.slug,
                        "id": site.id,
                        "publishedAt": site.published_at,
                    }
                    for site in entry.affected_sites
                ],
            }
            if entry.page_search_error:
                item["page_search_error"] = entry.page_search_error
            dead_links.append(item)

        return {
            "status": "dead_links_found" if self.dead_count > 0 else "ok",
            "checked": self.checked,
            "ok_count": self.ok_count,
            "dead_count": self.dead_count,
            "error_count": self.error_count,
            "warnings": list(self.warnings),
            "dead_links": dead_links,
            "log_path": config.log_path,
            "dead_log_path": config.dead_log_path,
        }


def _parse_csv(value: str | None, default: str) -> tuple[str, ...]:
    raw = value if value is not None else default
    return tuple(item.strip() for item in raw.split(",") if item.strip())


def _parse_int(value: str | None, default: int) -> int:
    if value is None or value.strip() == "":
        return default
    return int(value)


def _parse_bool(value: str | None, default: bool) -> bool:
    if value is None or value.strip() == "":
        return default
    return value.strip().lower() in ("1", "true", "yes", "on")


# Live Strapi roots whose attached component trees are scanned for hrefs.
LIVE_CONTENT_ROOTS: tuple[tuple[str, str, str], ...] = (
    (
        "pages",
        "pages_components",
        "SELECT id FROM pages WHERE published_at IS NOT NULL AND soft_deleted_at IS NULL",
    ),
    ("globals", "globals_components", "SELECT id FROM globals"),
    ("navs", "navs_components", "SELECT id FROM navs"),
)


def _require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise ConfigError(f"required environment variable {name} is not set")
    return value


def emit_json(payload: dict) -> None:
    text = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    sys.stdout.write(text)
    sys.stdout.flush()
    sys.stderr.write(text)
    sys.stderr.flush()


def emit_error_and_exit(message: str, exit_code: int = 1) -> None:
    emit_json({"status": "error", "message": message})
    sys.exit(exit_code)


def open_controlling_tty() -> TextIO | None:
    if os.getenv("DEADLINKS_PROGRESS_TO_TTY", "1") == "0":
        return None
    try:
        return open("/dev/tty", "w", encoding="utf-8")
    except OSError:
        return None


def write_tty(tty: TextIO | None, text: str) -> None:
    if tty is None:
        return
    tty.write(text if text.endswith("\n") else text + "\n")
    tty.flush()


def load_config() -> DeadLinksConfig:
    load_dotenv(Path(".env"))

    return DeadLinksConfig(
        database_name=_require_env("DEADLINKS_DATABASE_NAME"),
        database_user=_require_env("DEADLINKS_DATABASE_USERNAME"),
        database_password=_require_env("DEADLINKS_DATABASE_PASSWORD"),
        database_host=_require_env("DEADLINKS_DATABASE_HOST"),
        database_port=_require_env("DEADLINKS_DATABASE_PORT"),
        strapi_url=_require_env("DEADLINKS_STRAPI_URL"),
        strapi_api_key=os.getenv("DEADLINKS_STRAPI_API_KEY"),
        old_urls=_parse_csv(os.getenv("DEADLINKS_FRONTEND_URL"), ""),
        basic_auth_username=os.getenv("DEADLINKS_BASIC_AUTH_USERNAME"),
        basic_auth_password=os.getenv("DEADLINKS_BASIC_AUTH_PASSWORD"),
        product_url_patterns=_parse_csv(
            os.getenv("DEADLINKS_PRODUCT_URL_PATTERNS"),
            "/produkt/,/product/",
        ),
        protected_frontend_hosts=_parse_csv(
            os.getenv("DEADLINKS_PROTECTED_FRONTEND_HOSTS"),
            "dev.entiendoo.com,staging.entiendoo.com",
        ),
        log_path=os.getenv("DEADLINKS_LOG_PATH", "api_check.log"),
        dead_log_path=os.getenv("DEADLINKS_DEAD_LOG_PATH", "api_check_dead.log"),
        page_search_timeout=_parse_int(os.getenv("DEADLINKS_PAGE_SEARCH_TIMEOUT"), 60),
        frontend_check_timeout=_parse_int(os.getenv("DEADLINKS_FRONTEND_CHECK_TIMEOUT"), 30),
        strapi_check_timeout=_parse_int(os.getenv("DEADLINKS_STRAPI_CHECK_TIMEOUT"), 5),
        content_snippet_len=_parse_int(os.getenv("DEADLINKS_CONTENT_SNIPPET_LEN"), 120),
        skip_orphan_components=_parse_bool(os.getenv("DEADLINKS_SKIP_ORPHAN_COMPONENTS"), True),
    )


class TimestampedLogger:
    def __init__(self, log_path: str, tty: TextIO | None = None):
        self.log_path = log_path
        self.tty = tty

    def log(self, message: str) -> None:
        line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        write_tty(self.tty, line)


class FileOnlyLogger:
    def __init__(self, log_path: str, tty: TextIO | None = None):
        self.log_path = log_path
        self.tty = tty

    def log(self, message: str) -> None:
        line = f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {message}"
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")
        write_tty(self.tty, line)

    def log_block(self, header: str, body: str) -> None:
        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        header_line = f"[{timestamp}] {header}"
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(header_line + "\n")
            if body:
                f.write(body)
                if not body.endswith("\n"):
                    f.write("\n")
        write_tty(self.tty, header_line)
        if body:
            write_tty(self.tty, body if body.endswith("\n") else body + "\n")


def log_failure(
    logger: TimestampedLogger,
    dead_logger: FileOnlyLogger,
    message: str,
) -> None:
    logger.log(message)
    dead_logger.log(message)


def normalize_href(href: str) -> str:
    return href.strip().rstrip("/")


def is_product_url(href: str, patterns: tuple[str, ...]) -> bool:
    href_lower = href.lower()
    return any(pattern in href_lower for pattern in patterns)


def is_protected_frontend_host(href: str, protected_hosts: tuple[str, ...]) -> bool:
    host = urlparse(href).netloc.lower()
    return any(marker in host for marker in protected_hosts)


def check_href_direct(
    href: str,
    config: DeadLinksConfig,
    auth: HTTPBasicAuth | None = None,
) -> requests.Response:
    kwargs: dict = {
        "timeout": config.frontend_check_timeout,
        "allow_redirects": True,
        "headers": {"Accept": "text/html,application/json"},
    }
    if auth is not None and is_protected_frontend_host(href, config.protected_frontend_hosts):
        kwargs["auth"] = auth
    return requests.get(href, **kwargs)


def truncate_content(content, max_len: int) -> str:
    text = str(content) if content is not None else ""
    if len(text) <= max_len:
        return text
    return text[:max_len] + "..."


def is_component_content_table(table: str) -> bool:
    return (
        table.startswith("components_")
        and not table.endswith("_components")
        and not table.endswith("_links")
    )


def is_junction_table(table: str) -> bool:
    return table.endswith("_components") and not table.endswith("_links")


def component_type_to_table_candidates(component_type: str) -> tuple[str, ...]:
    if "." not in component_type:
        return ()
    category, name = component_type.split(".", 1)
    base = name.replace("-", "_")
    candidates = [
        f"components_{category}_{base}s",
        f"components_{category}_{base}",
    ]
    if base.endswith("s"):
        return (f"components_{category}_{base}", f"components_{category}_{base}s")
    if base.endswith("y"):
        candidates.append(f"components_{category}_{base[:-1]}ies")
    return tuple(dict.fromkeys(candidates))


def resolve_component_type_table(component_type: str, known_tables: set[str]) -> str | None:
    for candidate in component_type_to_table_candidates(component_type):
        if candidate in known_tables:
            return candidate
    return None


def build_component_type_table_map(
    cursor,
    junction_tables: tuple[str, ...],
    known_tables: set[str],
) -> dict[str, str]:
    type_to_table: dict[str, str] = {}
    for junction_table in junction_tables:
        cursor.execute(
            f'SELECT DISTINCT component_type FROM "{junction_table}" '
            "WHERE component_type IS NOT NULL"
        )
        for (component_type,) in cursor.fetchall():
            if component_type in type_to_table:
                continue
            table = resolve_component_type_table(component_type, known_tables)
            if table:
                type_to_table[component_type] = table
    return type_to_table


def build_reachable_component_ids(
    cursor,
    all_tables: list[str],
    logger: TimestampedLogger,
) -> dict[str, set[int]]:
    known_tables = set(all_tables)
    junction_tables = tuple(
        table for table in all_tables if is_junction_table(table)
    )
    type_to_table = build_component_type_table_map(cursor, junction_tables, known_tables)
    nested_junction_by_parent = {
        junction_table[: -len("_components")]: junction_table
        for junction_table in junction_tables
        if junction_table.startswith("components_")
    }

    reachable: dict[str, set[int]] = {}
    queue: list[tuple[str, int]] = []

    def mark_reachable(table: str, component_id: int) -> None:
        ids = reachable.setdefault(table, set())
        if component_id in ids:
            return
        ids.add(component_id)
        queue.append((table, component_id))

    for _entity_table, junction_table, live_query in LIVE_CONTENT_ROOTS:
        if junction_table not in known_tables:
            continue
        try:
            cursor.execute(live_query)
        except Exception as error:
            if "soft_deleted_at" in str(error) and "pages" in live_query:
                cursor.connection.rollback()
                cursor.execute(
                    "SELECT id FROM pages WHERE published_at IS NOT NULL"
                )
            else:
                raise
        live_ids = [row[0] for row in cursor.fetchall()]
        if not live_ids:
            continue

        cursor.execute(
            f'SELECT component_type, component_id FROM "{junction_table}" '
            "WHERE entity_id = ANY(%s)",
            (live_ids,),
        )
        for component_type, component_id in cursor.fetchall():
            table = type_to_table.get(component_type)
            if table and component_id is not None:
                mark_reachable(table, component_id)

    while queue:
        parent_table, parent_id = queue.pop(0)
        nested_junction = nested_junction_by_parent.get(parent_table)
        if not nested_junction:
            continue
        cursor.execute(
            f'SELECT component_type, component_id FROM "{nested_junction}" '
            "WHERE entity_id = %s",
            (parent_id,),
        )
        for component_type, component_id in cursor.fetchall():
            table = type_to_table.get(component_type)
            if table and component_id is not None:
                mark_reachable(table, component_id)

    total_ids = sum(len(ids) for ids in reachable.values())
    logger.log(
        "Skipping orphan component rows (reachable from published pages/globals/navs): "
        f"{total_ids} component IDs across {len(reachable)} tables"
    )
    return reachable


def parse_href_to_api_url(href: str, old_urls: tuple[str, ...], strapi_url: str) -> tuple[str, str] | None:
    path = href
    for url in old_urls:
        path = path.replace(url, "")

    path_segments = [seg for seg in path.split("/") if seg]
    if not path_segments:
        return None

    locale = path_segments[0]
    api_path = "/".join(path_segments[1:]) if len(path_segments) > 1 else ""
    encoded_path = quote(api_path, safe="")
    api_url = f"{strapi_url}/api/pages/{encoded_path}?locale={locale}"
    return locale, api_url


def href_to_search_terms(href: str, old_urls: tuple[str, ...]) -> tuple[str, ...]:
    """Build search terms for page-search: full URL plus locale path variants."""
    normalized_href = normalize_href(href)
    terms: list[str] = [normalized_href]

    path = normalized_href
    for url in old_urls:
        path = path.replace(normalize_href(url), "")

    locale_path = normalize_href(path)
    if locale_path and locale_path not in terms:
        terms.append(locale_path)

    return tuple(terms)


def href_to_search_word(href: str, old_urls: tuple[str, ...]) -> str | None:
    terms = href_to_search_terms(href, old_urls)
    return terms[0] if terms else None


def fetch_all_page_search(config: DeadLinksConfig, word: str) -> list[dict] | str:
    if not config.strapi_api_key:
        return "(page-search skipped: DEADLINKS_STRAPI_API_KEY not set)"

    all_data: list[dict] = []
    page = 1

    try:
        while True:
            response = requests.get(
                f"{config.strapi_url}/api/page-search",
                params={
                    "word": word,
                    "populate": "deep",
                    "fields[0]": "slug",
                    "fields[1]": "id",
                    "fields[2]": "publishedAt",
                    "pagination[page]": page,
                },
                headers={
                    **config.page_search_headers(),
                    "Authorization": f"Bearer {config.strapi_api_key}",
                },
                timeout=config.page_search_timeout,
            )
            response.raise_for_status()
            payload = response.json()
            all_data.extend(payload.get("data", []))

            pagination = payload.get("meta", {}).get("pagination", {})
            page_count = pagination.get("pageCount", 1)
            if page >= page_count:
                break
            page += 1

        return all_data
    except (requests.RequestException, ValueError) as error:
        return f"(page-search request failed: {error})"


def resolve_affected_sites(
    href: str,
    config: DeadLinksConfig,
) -> tuple[tuple[AffectedSite, ...], str | None, str | None]:
    search_terms = href_to_search_terms(href, config.old_urls)
    if not search_terms:
        return (), "(no search word — could not parse path)", None

    seen_ids: set[int | str] = set()
    matches: list[dict] = []
    for term in search_terms:
        result = fetch_all_page_search(config, term)
        if isinstance(result, str):
            return (), result, search_terms[0]

        for match in result:
            match_id = match.get("id")
            if match_id in seen_ids:
                continue
            seen_ids.add(match_id)
            matches.append(match)

    sites = tuple(
        AffectedSite(
            slug=match.get("slug", ""),
            id=match.get("id", ""),
            published_at=match.get("publishedAt"),
        )
        for match in matches
        if match.get("publishedAt") is not None
    )
    return sites, None, search_terms[0]


def format_dead_link_block(
    href: str,
    status_code: int,
    search_word: str | None,
    sites: tuple[AffectedSite, ...],
    error_message: str | None,
) -> tuple[str, str]:
    header = f"DEAD {status_code}: {href}"
    lines = ["----"]
    if error_message:
        lines.append(error_message)
    elif not sites:
        lines.append(f'page-search "{search_word}": no matches')
    else:
        lines.append(f'page-search "{search_word}" — {len(sites)} matches:')
        lines.append("")
        for site in sites:
            published = "(null)" if site.published_at is None else site.published_at
            lines.extend(
                [
                    f"slug:        {site.slug}",
                    f"id:          {site.id}",
                    f"publishedAt: {published}",
                    "",
                ]
            )
    return header, "\n".join(lines).rstrip() + "\n"


def collect_unique_hrefs(
    cursor,
    connection,
    all_tables: list[str],
    config: DeadLinksConfig,
    logger: TimestampedLogger,
    reachable_components: dict[str, set[int]] | None = None,
) -> dict[str, list[dict]]:
    unique_hrefs: dict[str, list[dict]] = {}
    total_tables = len(all_tables)
    old_urls = config.old_urls
    skip_orphans = config.skip_orphan_components and reachable_components is not None

    for table_index, table in enumerate(all_tables, start=1):
        logger.log(f"Scanning table {table} ({table_index}/{total_tables})...")
        try:
            table_name_quoted = f'"{table}"'
            cursor.execute(
                """
                SELECT column_name, data_type
                FROM information_schema.columns
                WHERE table_name = %s
                """,
                (table,),
            )
            columns = cursor.fetchall()
            column_names = [col[0] for col in columns]
            id_column = column_names[0] if "id" not in column_names else "id"

            for col_name, col_type in columns:
                if col_type not in ("text", "varchar", "char", "jsonb"):
                    continue

                column_name_quoted = f'"{col_name}"'
                try:
                    conditions = " OR ".join([f"{column_name_quoted}::text ILIKE %s" for _ in old_urls])
                    extra_where = ""
                    if skip_orphans and table == "pages":
                        extra_where = " AND published_at IS NOT NULL"
                    sql_query = (
                        f"SELECT {id_column}, {column_name_quoted} "
                        f"FROM {table_name_quoted} WHERE ({conditions}){extra_where}"
                    )
                    cursor.execute(sql_query, tuple(f"%{url}%" for url in old_urls))
                    rows = cursor.fetchall()

                    for row in rows:
                        row_id = row[0]
                        if skip_orphans and is_component_content_table(table):
                            if row_id not in reachable_components.get(table, set()):
                                continue

                        content = row[1]
                        if content is None:
                            continue

                        content_text = str(content)
                        hrefs = HREF_PATTERN.findall(content_text)

                        for href in hrefs:
                            if not any(url in href for url in old_urls):
                                continue

                            normalized = normalize_href(href)
                            occurrence = {
                                "table": table,
                                "col_name": col_name,
                                "row_id": row_id,
                                "content_snippet": truncate_content(
                                    content, config.content_snippet_len
                                ),
                            }
                            unique_hrefs.setdefault(normalized, []).append(occurrence)
                except Exception as column_error:
                    logger.log(f"Error querying column '{col_name}' in table '{table}': {column_error}")
                    connection.rollback()
                    continue
        except Exception as table_error:
            logger.log(f"Error processing table '{table}': {table_error}")
            connection.rollback()
            continue

    logger.log(f"Found {len(unique_hrefs)} unique hrefs to check.")
    return unique_hrefs


def check_unique_hrefs(
    unique_hrefs: dict[str, list[dict]],
    config: DeadLinksConfig,
    frontend_auth: HTTPBasicAuth | None,
    logger: TimestampedLogger,
    dead_logger: FileOnlyLogger,
) -> RunResult:
    checked = 0
    ok_count = 0
    dead_count = 0
    error_count = 0
    skip_count = 0
    dead_links: list[DeadLinkEntry] = []
    total = len(unique_hrefs)

    for index, (href, occurrences) in enumerate(unique_hrefs.items(), start=1):
        logger.log(f"Checking href ({index}/{total}): {href}")

        is_direct_check = is_product_url(href, config.product_url_patterns)

        if is_direct_check:
            logger.log("  → product URL: direct HTTP check")
        else:
            parsed = parse_href_to_api_url(href, config.old_urls, config.strapi_url)
            if parsed is None:
                skip_count += 1
                log_failure(logger, dead_logger, f"SKIP: {href} — no locale/path")
                for occ in occurrences:
                    log_failure(
                        logger,
                        dead_logger,
                        f"  - {occ['table']}.{occ['col_name']} (id={occ['row_id']})",
                    )
                continue

        try:
            if is_direct_check:
                response = check_href_direct(href, config, frontend_auth)
            else:
                _, api_url = parsed
                response = requests.get(api_url, timeout=config.strapi_check_timeout)

            checked += 1

            if response.status_code == 200:
                ok_count += 1
                if is_direct_check:
                    logger.log(f"OK (direct): {href}")
                else:
                    logger.log(f"OK: {href}")
            else:
                dead_count += 1
                check_type = "direct" if is_direct_check else "strapi"
                sites, page_search_error, search_word = resolve_affected_sites(
                    href, config
                )
                dead_links.append(
                    DeadLinkEntry(
                        href=href,
                        status_code=response.status_code,
                        check_type=check_type,
                        affected_sites=sites,
                        page_search_error=page_search_error,
                    )
                )
                if is_direct_check:
                    logger.log(f"DEAD (direct, {response.status_code}): {href}")
                else:
                    logger.log(f"DEAD ({response.status_code}): {href}")
                for occ in occurrences:
                    logger.log(f"  - {occ['table']}.{occ['col_name']} (id={occ['row_id']})")
                header, body = format_dead_link_block(
                    href,
                    response.status_code,
                    search_word,
                    sites,
                    page_search_error,
                )
                dead_logger.log_block(header, body)
        except requests.RequestException as api_error:
            checked += 1
            error_count += 1
            log_failure(logger, dead_logger, f"ERROR: {href} — {api_error}")
            for occ in occurrences:
                log_failure(
                    logger,
                    dead_logger,
                    f"  - {occ['table']}.{occ['col_name']} (id={occ['row_id']})",
                )

    return RunResult(
        checked=checked,
        ok_count=ok_count,
        dead_count=dead_count,
        error_count=error_count + skip_count,
        dead_links=tuple(dead_links),
    )


def emit_pipeline_output(result: RunResult, config: DeadLinksConfig) -> None:
    emit_json(result.to_json_dict(config))


def main() -> None:
    config = load_config()

    if not config.old_urls:
        emit_error_and_exit("DEADLINKS_FRONTEND_URL must contain at least one URL")

    frontend_auth = config.get_frontend_basic_auth()
    warnings: list[str] = []
    tty = open_controlling_tty()

    try:
        logger = TimestampedLogger(config.log_path, tty=tty)
        dead_logger = FileOnlyLogger(config.dead_log_path, tty=tty)
        logger.log(f"=== Run started: database={config.database_name} ===")
        dead_logger.log(f"=== Run started: database={config.database_name} ===")

        if frontend_auth and is_protected_frontend_host(
            config.primary_frontend_url, config.protected_frontend_hosts
        ):
            logger.log("Frontend basic auth enabled for dev/staging checks")
        elif is_protected_frontend_host(
            config.primary_frontend_url, config.protected_frontend_hosts
        ) and not frontend_auth:
            warnings.append(
                "dev/staging FRONTEND_URL but DEADLINKS_BASIC_AUTH_USERNAME/PASSWORD not set"
            )
            logger.log(f"Warning: {warnings[-1]}")

        connection = psycopg2.connect(
            database=config.database_name,
            user=config.database_user,
            password=config.database_password,
            host=config.database_host,
            port=config.database_port,
        )
        cursor = connection.cursor()

        try:
            cursor.execute(
                """
                SELECT table_name
                FROM information_schema.tables
                WHERE table_schema = 'public'
                """
            )
            all_tables = [table[0] for table in cursor.fetchall()]

            reachable_components = None
            if config.skip_orphan_components:
                reachable_components = build_reachable_component_ids(
                    cursor, all_tables, logger
                )

            unique_hrefs = collect_unique_hrefs(
                cursor,
                connection,
                all_tables,
                config,
                logger,
                reachable_components,
            )
            check_result = check_unique_hrefs(
                unique_hrefs, config, frontend_auth, logger, dead_logger
            )
            result = RunResult(
                checked=check_result.checked,
                ok_count=check_result.ok_count,
                dead_count=check_result.dead_count,
                error_count=check_result.error_count,
                dead_links=check_result.dead_links,
                warnings=tuple(warnings),
            )

            logger.log(
                f"Done: {result.checked} checked, {result.ok_count} ok, "
                f"{result.dead_count} dead, {result.error_count} errors/skipped"
            )
            if result.dead_count + result.error_count > 0:
                dead_logger.log(
                    f"=== Run finished: {result.dead_count} dead, "
                    f"{result.error_count} errors/skipped ==="
                )

            emit_pipeline_output(result, config)
            sys.exit(1 if result.dead_count > 0 else 0)
        finally:
            cursor.close()
            connection.close()
    finally:
        if tty is not None:
            tty.close()


if __name__ == "__main__":
    try:
        main()
    except ConfigError as error:
        emit_error_and_exit(str(error))
    except Exception as error:
        emit_error_and_exit(str(error))

