import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_get_gists():

    response = client.get("/octocat")

    assert response.status_code == 200
    assert "gists" in response.json()