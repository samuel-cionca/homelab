import subprocess

from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/dead-links")
def dead_links():
    result = subprocess.run(
        ["python", "find-dead-links-in-db.py"],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return {
            "success": False,
            "message": "Dead-link checker failed",
            "returncode": result.returncode,
            "stderr": result.stderr,
            "stdout": result.stdout,
        }

    return {
        "success": True,
        "message": "Dead-link check completed successfully",
        "stdout": result.stdout,
        "stderr": result.stderr,
    }
