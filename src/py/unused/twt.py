#!/usr/bin/env python3

import twitter


def twitter_api(consumer_key, consumer_secret, access_key, access_secret):
    return twitter.Api(
        consumer_key=consumer_key,
        consumer_secret=consumer_secret,
        access_token_key=access_key,
        access_token_secret=access_secret,
    )
