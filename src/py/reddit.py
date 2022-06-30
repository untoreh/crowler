import praw

def get_subreddit(sub: str, ua: str, id, secret, u, p):
    return praw.Reddit(
        client_id=id,
        client_secret=secret,
        user_agent=ua,
        username=u,
        password=p,
    ).subreddit(sub)
