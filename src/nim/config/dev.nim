import uri
import ./base

const
    WEBSITE_DOMAIN* = "wsl"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "A test website."
    WEBSITE_DESCRIPTION* = "This is a test description"
    WEBSITE_CONTACT* = "contact@example.com"
    WEBSITE_TWITTER* = "https://twitter.com/dev"
    WEBSITE_FACEBOOK* = "devfb"
    WEBSITE_PINTEREST* = "devpinterest"
    WEBSITE_WEIBO* = "devweibo"
    WEBSITE_REDDIT* = "devreddit"
