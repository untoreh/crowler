import karax / vdom

import cfg

static: echo "loading minify_html_c..."

proc minify*(code: cstring,
             do_not_minify_doctype: bool = false,
             ensure_spec_compliant_unquoted_attribute_values: bool = false,
             keep_closing_tags: bool = true,
             keep_comments: bool = false,
             keep_html_and_head_opening_tags: bool = true,
             keep_spaces_between_attributes: bool = false,
             minify_css: bool = true,
             minify_js: bool = true,
             remove_bangs: bool = true,
                           remove_processing_instructions: bool = true): cstring {.importc: "minify".}

proc minifyHtml*(tree: VNode): string = $minify(($tree).cstring)
proc minifyHtml*(data: string): string = $minify(data.cstring)

when isMainModule:
    let html: cstring = "<!doctype html> <body> asd </body> </html>"
    let mn = minify(html)
    echo $mn
# echo mn.isnil
# echo $mn
