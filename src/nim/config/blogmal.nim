import uri

import ./base

const
    WEBSITE_NAME* = "wsl"
    WEBSITE_DOMAIN* = "wsl"
    WEBSITE_URL* = parseUri("https://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "The wsl"
    WEBSITE_DESCRIPTION* = "The curated readling list, categorized news and articles."
    WEBSITE_CONTACT* = "contact@wsl"
    CRON_TOPIC_FREQ_MAX* = 3600 * 6
    CRON_TOPIC_FREQ_MIN* = 1800
