import karax/[vdom, karaxdsl], strformat

const
    # ADSENSE_ID* =
    ADSENSE_SRC* = """<script async src="https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js?client=ca-pub-7303639355435813"
     crossorigin="anonymous"></script>"""
    ADSENSE_AMP_HEAD* = """<script async custom-element="amp-auto-ads"
        src="https://cdn.ampproject.org/v0/amp-auto-ads-0.1.js">
</script>"""
    ADSENSE_AMP_BODY* = """<amp-auto-ads type="adsense"
        data-ad-client="ca-pub-7303639355435813">
</amp-auto-ads>"""
