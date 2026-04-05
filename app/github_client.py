import requests

GITHUB_URL = "https://api.github.com/users/{}/gists"

def get_public_gists(username):

    url = GITHUB_URL.format(username)

    response = requests.get(url)

    if response.status_code == 404:
        raise Exception("GitHub user not found")

    if response.status_code != 200:
        raise Exception("GitHub API error")

    gists = response.json()

    result = []

    for gist in gists:
        result.append({
            "id": gist["id"],
            "description": gist["description"],
            "url": gist["html_url"],
            "files": list(gist["files"].keys())
        })

    return result