import uri
import ./base

const
    WEBSITE_NAME* = "wsl"
    WEBSITE_DOMAIN* = "wsl"
    WEBSITE_URL* = parseUri("https://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "wsl"
    WEBSITE_DESCRIPTION* = "Everything about server hosting."
    WEBSITE_CONTACT* = "contact@wsl"
    CRON_TOPIC_FREQ_MAX* = 3600 * 3
    CRON_TOPIC_FREQ_MIN* = 3600
