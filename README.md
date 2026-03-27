# GitHub Gists API

A simple HTTP web server API built with FastAPI that interacts with the GitHub API to retrieve a user's publicly available Gists.

## Features

- Fetch public Gists for any GitHub user
- Returns structured JSON response with gist details
- Packaged in a Docker container
- Includes automated tests

## API Endpoint

### GET /{username}

Retrieves the public Gists for the specified GitHub username.

**Response:**
```json
{
  "username": "octocat",
  "count": 8,
  "gists": [
    {
      "id": "6cad326836d38bd3a7ae",
      "description": "Hello world!",
      "url": "https://gist.github.com/octocat/6cad326836d38bd3a7ae",
      "files": [
        "hello_world.rb"
      ]
    },
    {
      "id": "0831f3fbd83ac4d46451",
      "description": "",
      "url": "https://gist.github.com/octocat/0831f3fbd83ac4d46451",
      "files": [
        "git-author-rewrite.sh"
      ]
    },
    {
      "id": "2a6851cde24cdaf4b85b",
      "description": "",
      "url": "https://gist.github.com/octocat/2a6851cde24cdaf4b85b",
      "files": [
        "ssh_key_add.sh"
      ]
    },
    {
      "id": "9257657",
      "description": "Some common .gitignore configurations",
      "url": "https://gist.github.com/octocat/9257657",
      "files": [
        ".gitignore"
      ]
    },
    {
      "id": "1305321",
      "description": null,
      "url": "https://gist.github.com/octocat/1305321",
      "files": [
        "test.cs"
      ]
    },
    {
      "id": "1169854",
      "description": null,
      "url": "https://gist.github.com/octocat/1169854",
      "files": [
        "test.cs"
      ]
    },
    {
      "id": "1169852",
      "description": null,
      "url": "https://gist.github.com/octocat/1169852",
      "files": [
        "test.cs"
      ]
    },
    {
      "id": "1162032",
      "description": null,
      "url": "https://gist.github.com/octocat/1162032",
      "files": [
        "test.cs"
      ]
    }
  ]
}
```

## Installation

### Prerequisites

- Python 3.11+
- Docker (optional, for containerized deployment)

### Local Development

1. Clone the repository:
   ```bash
   git clone <repository-url>
   cd equal-experts-hardy-humorous-quiet-sport
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

3. Run the application:
   ```bash
   uvicorn app.main:app --host 0.0.0.0 --port 8080
   ```

The API will be available at `http://localhost:8080`.

## Docker Deployment

1. Build the Docker image:
   ```bash
   docker build -t github-gists-api:v1 -f docker/Dockerfile .
   ```

2. Run the container:
   ```bash
   docker run -d -p 8080:8080 --name github-gists-api-v1 github-gists-api:v1
   ```

The API will be available at `http://localhost:8080`.

## Testing

Run the automated tests:

```bash
pytest tests/
```

The test validates the API endpoint using the `octocat` user as test data.

## Project Structure

```
.
├── README.md
├── requirements.txt
├── app/
│   ├── __init__.py
│   ├── github_client.py  # GitHub API client
│   └── main.py          # FastAPI application
├── docker/
│   └── Dockerfile       # Docker configuration
└── tests/
    └── test_api.py      # API tests
```
