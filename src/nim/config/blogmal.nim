import uri

import ./base

const
    WEBSITE_NAME* = "wsl"
    WEBSITE_DOMAIN* = "wsl"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "The wsl"
    WEBSITE_DESCRIPTION* = "The curated readling list, categorized news and articles."
    WEBSITE_CONTACT* = "contact@wsl"
    WEBSITE_TWITTER* = "https://twitter.com/wsl"
    WEBSITE_FACEBOOK* = "wslfb"
    WEBSITE_PINTEREST* = "wslinterest"
    WEBSITE_WEIBO* = "wslweibo"
    WEBSITE_REDDIT* = "wslreddit"
