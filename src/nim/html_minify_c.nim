import karax / vdom

import cfg

static: echo "loading minify_html_c..."

proc minify*(code: cstring,
             do_not_minify_doctype = false,
             ensure_spec_compliant_unquoted_attribute_values = false,
             keep_closing_tags = true,
             keep_comments = false,
             keep_html_and_head_opening_tags = true,
             keep_spaces_between_attributes = false,
             minify_css = true,
             minify_js = true,
             remove_bangs = false,
             remove_processing_instructions = true): cstring {.importc: "minify".}

proc minifyHtml*(tree: VNode): string = $minify(($tree).cstring)
proc minifyHtml*(data: string): string = $minify(data.cstring)
template minifyHtml*(data: string, args: varargs[untyped]): string =
    $minify(data.cstring, args)

when isMainModule:
    let html: cstring = "<!doctype html> <body> asd </body> </html>"
    let mn = minify(html)
    # echo $mn
# echo mn.isnil
# echo $mn
