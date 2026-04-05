from fastapi import FastAPI, HTTPException
from app.github_client import get_public_gists

app = FastAPI(title="GitHub Gists API")

@app.get("/{username}")
def fetch_gists(username: str):
    try:
        gists = get_public_gists(username)

        return {
            "username": username,
            "count": len(gists),
            "gists": gists
        }

    except Exception as ex:
        raise HTTPException(status_code=500, detail=str(ex))