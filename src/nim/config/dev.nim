import uri
import ./base

const
    WEBSITE_NAME* = "dev"
    WEBSITE_DOMAIN* = "wsl"
    WEBSITE_URL* = parseUri("http://" & WEBSITE_DOMAIN & WEBSITE_DEBUG_PORT)
    WEBSITE_TITLE* = "A test website."
    WEBSITE_DESCRIPTION* = "This is a test description"
    WEBSITE_CONTACT* = "contact@example.com"
