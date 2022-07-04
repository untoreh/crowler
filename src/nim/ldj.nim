import json,
       times,
       macros,
       tables,
       strformat,
       uri,
       strutils,
       sugar,
       hashes,
       std/enumerate,
       karax/vdom

import
    cfg,
    types,
    utils,
    html_misc,
    articles

export utils, tables, html_misc

type Organization = ref tuple
    name: string
    url: string
    contact: string
    tel: string
    email: string
    sameas: string
    logo: string

threadVars(
    (EMPTY_DATE, DateTime),
    (ldj_country, ldj_region, string),
    (jsonCache, Table[Hash, JsonNode]),
    (J, JsonNode),
    (S, seq[string]),
    (ST, seq[(string, string)]),
    (ldjElement, VNode),
    (OG, Organization)
)
export jsonCache

macro jm*(code: typed): untyped =
    code.expectKind nnkCall
    code[0].expectKind nnkSym
    let fname = code[0]
    let tup = nnkTupleConstr.newTree(code[1..^1])
    quote do:
        block:
            # NOTE: this will fail if the arguments have openarrays!
            let
                etup = `tup`
                h = hash(etup)
            try:
                jsonCache[h]
            except KeyError:
                jsonCache[h] = `fname`.apply(etup)
                jsonCache[h]

proc isempty(s: string): bool {.inject.} = s.isEmptyOrWhiteSpace

template setProps(): untyped {.dirty.} =
    if (not props.isnil) and (props.kind != JNull):
        for (p, v) in props.pairs():
            data[p] = v

proc setArgs[T](data: T, args: JsonNode) =
    for (k, v) in args.pairs():
        data[k] = v

template withSchema(json: JsonNode): JsonNode =
    json["@context"] = %"https://schema.org/"
    json

proc asVNode*[T](data: T, wrap = true, id = "", class = ""): VNode {.gcsafe.} =
    ldjElement.clearChildren
    case wrap:
        of true:
            result = deepCopy(ldjElement)
            if id != "":
                result.setAttr("id", id)
            if class != "":
                result.setAttr("class", class)
            result.add verbatim($data)
        else:
            result = deepCopy(ldjElement)

const emptyCpr = (holder: "", year: "")
proc jwebsite(url, author, year: auto, image = "", cpr: tuple[holder, year: string] = emptyCpr): JsonNode =
    ## "https://schema.org/WebSite"
    result = withSchema:
        %* {
            "@type": "WebSite",
            "@id": url,
            "url": url,
            "image": image
        }
    if cpr.holder != "":
        result["copyrightHolder"] = %cpr.holder
        result["copyrightYear"] = %cpr.year

template website*(code: varargs[untyped]): JsonNode = jm jwebsite(`code`)

var searchUri {.threadvar.}: ref Uri
proc search(url: string, parts: Uri, maxlength = 100): JsonNode =
    ## "https://schema.org/SearchAction
    assert "{input}" in parts.query
    parseURI(url, searchUri[])
    %* {
        "potentialAction": {
            "@type": "SearchAction",
            "target": searchUri.mergeUri(parts),
            "query": "required",
            "query-input": fmt"required maxlength={maxlength} name=input",
            "actionStatus": "https://schema.org/PotentialActionStatus",
        }
    }

proc place(place = "homeLocation"; country = "", region = "", props: JsonNode = default(
        JsonNode)): JsonNode =
    ## "https://schema.org/Place"
    var data = %* {
        place: {
            "@type": "https://schema.org/Place",
                 "addressCountry": ldj_country,
                 "addressRegion": ldj_region,
        },
    }
    if not country.isEmptyOrWhitespace:
        data["addressCountry"] = %country
    if not region.isEmptyOrWhitespace:
        data["addressRegion"] = %region

    setProps
    data

proc jauthor(entity = "Person"; name, email = "", description = "", image = "",
        sameAs = ""): JsonNode =
    ## "Convenience function for authors. Requires at least `name` and `email`."
    var data = %* {
        "@type": "https://schema.org/$(entity)",
        "name": name,
        "email": email
    }
    setArgs(data, %*{"image": image, "description": description, "sameAs": sameAs})
    data

template author*(code: varargs[untyped]): JsonNode = jm jauthor(code)

template publisher(code: untyped): untyped =
    ## Currently same as `author`.
    ## NOTE: a publisher should not be a person.
    author(code)

proc languages(langs: auto): JsonNode =
    ## Create a list of Language types
    var ll: seq[JsonNode]
    for l in langs:
        ll.add %*{"@type": "Language", "name": l}
    %ll


# proc coerce[V, T](val: V, what: V = default(V), to: V = ""): T {.inline.} =
#     ## convert VAL to TO if equal to WHAT, otherwise return VAL.
#     if val == what: return to
#     val
macro coerce(val, to: untyped = ""): untyped =
    ## convert VAL to TO if equal to WHAT, otherwise return VAL.
    quote do:
        if `val` == default(typeof(`val`)):
            `to` else: `val`

macro coerce(val, what, to: untyped): untyped =
    ## convert VAL to TO if equal to WHAT, otherwise return VAL.
    quote do:
        if `val` == `what`:
            `to` else: `val`

macro coercf[T](val: T, fn: (T) -> bool = isEmptyOrWhiteSpace, to: T): T =
    ## convert VAL to TO if FN returns true, otherwise return VAL.
    quote do:
        if `fn`(`val`): `to` else: `val`

proc toIsoDate(date: string): string =
    try:
        return date.parseTime(isoFormat, utc()).format(isoformat)
    except:
        return date

proc ensure_time(modified: string, created: string, defv = now()): string =
    if modified.isEmptyOrWhitespace:
        if created.isEmptyOrWhitespace:
            return format(defv, isoformat)
        return created.toIsoDate
    modified.toIsoDate

proc jwebpage(id, title, url, mtime, selector, description: auto, keywords: seq[string], name = "", headline = "",
            image = "", entity = "Article", status = "Published", lang = "english", mentions: seq[
            string] = (@[]), access_mode = (@["textual", "visual"]), access_sufficient: seq[
            string] = @[], access_summary = "", created = "", published = "",
            props = default(JsonNode)): JsonNode =
    let
        d_mtime = coerce(mtime, "")
        s_created = created.toIsoDate
        description = coerce(description, to = title)
        prd = (v: seq[string]) => v.len == 0

    let data = %*{
        "@context": "https://schema.org",
        "@type": "https://schema.org/WebPage",
        "@id": id,
        "url": url,
        "lastReviewed": coerce(mtime, ""),
        "mainEntityOfPage": {
            "@type": entity,
            "@id": url
        },
        "mainContentOfPage":
        {
            "@type": "WebPageElement", "cssSelector": selector},
        "accessMode": access_mode,
        "accessModeSufficient": {
            "@type": "itemList",
            "itemListElement": coercf(access_sufficient, prd, to = access_mode),
        },
        "creativeWorkStatus": status,
        # NOTE: datePublished should always be provided
        "datePublished": ensure_time(d_mtime.toIsoDate, s_created),
        "dateModified": d_mtime,
        "dateCreated": coerce(s_created, to = d_mtime),
        "name": coerce(name, to = title),
        "description": coerce(description, ""),
        "keywords": coerce(keywords, to = (@[]))
    }
    setArgs data, %*{"inLanguage": lang, "accessibilitySummary": access_summary,
                    "headline": coerce(headline, to = description), "image": image,
                    "mentions": mentions}
    setProps
    data


template webpage*(id: string, code: varargs[untyped]): string =
    let k = hash(id)
    try:
        $jsonCache[k]
    except:
        jsonCache[k] = jwebpage(id, `code`)
        $jsonCache[k]

proc translation*(src_url, trg_url, lang, title, mtime, selector, description: auto, keywords: seq[string],
                     image = "", headline = "", props = default(JsonNode),
                     translator_name = "Google", translator_url = "https://translate.google.com/"): auto =
    ## file path must be relative to the project directory, assumes the published website is under '__site/'
    # id, title, url, mtime, selector, description: auto, keywords: seq[string], name = "", headline = "",
    let data = jwebpage(id = trg_url, title, url = trg_url, mtime, selector, description,
                            keywords = keywords, image = image, headline = headline, lang = lang, props = props)
    data["translator"] = %*{"@type": "https://schema.org/Organization",
                             "name": translator_name,
                             "url": translator_url}
    data["translationOfWork"] = %*{"@id": src_url}
    data

proc jbreadcrumbs(crumbs: seq[(string, string)]): JsonNode =
    ## Take a list of (name, link) tuples and returns a breadcrumb
    ## definition with hierarchy from top to bottom.
    let nodes = collect:
        for n, (name, item) in enumerate(crumbs.items):
            %*{
                "@type": "BreadcrumbList",
                "itemListElement": [
                    {
                        "@type": "ListItem",
                        "position": n,
                        "name": name,
                        "item": item
                        }
                        ]
                        }
    %nodes

template breadcrumbs*(code: untyped): JsonNode = jm jbreadcrumbs(`code`)

proc crumbsNode*(a: Article): auto =
    @[("Home", $WEBSITE_URL),
        ("Page", $(WEBSITE_URL / a.topic / $a.page)),
        ("Post", getArticleUrl(a))]

type
    Book = ref tuple
        name: string
        author: string
        url: string
        sameas: string
        tags: seq[string]
        comments: string

proc initBook(): Book = new(result)

proc book(name, author, url, tags, sameas: auto): JsonNode =
    result = withSchema:
        %*{
            "@type": "Book",
            "@id": url,
            "url": url,
            "urlTemplate": url,
            "name": name,
            "author": {
                "@type": "Person",
                "name": author
            },
            "sameAs": sameas
        }

    if not url.isEmptyOrWhitespace:
        result["url"] = %url
        result["@id"] = %url
        result["urlTemplate"] = %url

proc book(b: Book): JsonNode = book(b.name, b.author, b.url, b.tags, b.sameas)

proc bookfeed(books: auto, props = default(JsonNode)): JsonNode =
    let data = withSchema:
        %*{
            "@type": "DataFeed",
            "dataFeedElement": collect(for b in books: book(b))
        }
    setProps

proc eventStatus(status: string): string =
    let schema = "https://schema.org/Event"
    case status:
        of "cancelled":
            schema & "Cancelled"
        of "moved":
            schema & "MovedOnline"
        of "postponed":
            schema & "Postponed"
        of "rescheduled":
            schema & "Rescheduled"
        else:
            schema & "Scheduled"

proc onlineEvent(name, start_date, end_date, url: auto, image: seq[string] = @[], desc = "",
                 status = "EventScheduled", prev_date = "", perf = J, org = J,
                         offers = J): JsonNode =
    result = withSchema:
        %*{
            "@type": "Event",
            "name": name,
            "startDate": start_date.toIsoDate,
            "endDate": end_date.toIsoDate,
            "previousStartDate": prev_date,
            "eventStatus": event_status(status),
            "eventAttendanceMode": "https://schema.org/OnlineEventAttendanceMode",
            "location": {
                "@type": "VirtualLocation",
                "url": url
            },
            "image": image,
            "description": desc,
            "offers": offers,
            "performer": perf,
            "organizer": org
                }

proc license(name = ""): JsonNode =
    result = %(case name:
        of "mit":
            "https://en.wikipedia.org/wiki/MIT_License"
        of "apache":
            "https://en.wikipedia.org/wiki/Apache_License"
        of "gpl", "gplv3":
            "https://www.gnu.org/licenses/gpl-3.0.html"
        of "gplv2":
            "https://www.gnu.org/licenses/old-licenses/gpl-2.0.html"
        of "sol":
            "https://wiki.p2pfoundation.net/Copysol_License"
        of "crypto", "cal":
            "https://raw.githubusercontent.com/holochain/cryptographic-autonomy-license/master/README.md"
        else:
            "https://creativecommons.org/publicdomain/zero/1.0/")


proc initOrganization(): Organization = new(result)

proc jorgschema(name, url: string; contact = "", tel = "", email = ""; sameas: string | JsonNode = "",
        logo = ""): JsonNode =
    result = %*{
        "@type": "Organization",
        "name": name,
        "url": url,
        "logo": logo,
        "sameAs": sameas,
        "contactPoint": {"@type": "ContactPoint",
            "contactType": contact,
            "telephone": tel,
            "email": email, }
        }

template orgschema*(code: varargs[untyped]): JsonNode = jm jorgschema(code)

proc orgschema*(org: Organization): JsonNode =
    jm jorgschema(org.name, org.url, org.contact, org.tel, org.email, org.sameas, org.logo)


proc coverage(start_date, end_date = ""): string =
    start_date & "/" & (if end_date.isEmptyOrWhiteSpace: ".." else: end_date)

proc place_schema(coords = ""): JsonNode =
    %*{
        "@type": "Place",
        "geo": {
            "@type": "GeoShape",
            "box": coords
        }
        }

proc dataset(name, url, desc = "", sameas = "", id = "",
                 keywords = S, parts = S, license = "", access = true,
                 creator = J, funder = J, catalog = "", dist = ST,
                 start_date = "", end_date = "", coords = ""): JsonNode =
    ## dist is a tuple of (format, url) for content format and download link
    let distrib = collect:
        for (f, d) in dist:
            %* {
                    "@type": "DataDownload",
                    "encodingFormat": f,
                    "contentUrl": d
            }

    %*{
        "@type": "Dataset",
        "name": name,
        "url": url,
        "description": desc,
        "sameAs": sameas,
        "identifier": (if id.isempty: url else: id),
        "keywords": keywords,
        "hasPart": parts,
        "license": license,
        "isAccessibleForFree": access,
        "creator": creator,
        "funder": funder,
        "includedInDataCatalog": {
            "@type": "DataCatalog",
            "name": catalog
        },
        "distribution": distrib,
        "temporalCoverage": (if isempty(start_date): start_date
            else: coverage(start_date, end_date)),
        "spatialCoverage": place_schema(coords)
    }

proc faqschema(faqs: openarray[(string, string)]): JsonNode =
    let entity = collect:
        for (question, answer) in faqs:
            %*{
                "@type": "Question",
                "name": question,
                "acceptedAnswer": {
                    "@type": "Answer",
                    "text": answer
                }
                }
    withSchema:
        %*{
            "@type": "FAQPage",
            "mainEntity": entity
            }

proc cost(tp, currency = "USD", value = "0"): JsonNode =
    ## estimatedCost, MonetaryAmount (monetary) or Text
    if tp == "monetary":
        %*{
            "@type": "MonetaryAmount",
            "currency": currency,
            "value": value
            }
    else:
        %tp
proc cost(tp, currency = "USD", value: int): JsonNode = cost(tp, currency, $value)

proc image(url, width = "", height = "", license = (license: "", acquire: "")): JsonNode =
    withSchema:
        %*{
            "@type": "ImageObject",
            "url": url,
            "width": width,
            "height": height,
            "license": license.license,
            "acquireLicensePage": license.acquire
            }

proc howtoitem(name: string, tp = "supply", props = J): JsonNode =
    ## create an HowToSupply, HowToTool or HowToStep
    var t: string
    case name:
        of "supply":
            t = "HowToSupply"
        of "item":
            t = "HowToItem"
        of "direction":
            t = "HowToDirection"
        of "tip":
            t = "HowToTip"
        else:
            t = "HowToStep"

    let data = %*{
        "@type": t,
        "name": name
        }
    setProps
    result = data

proc howto(name, desc = "", image = J, cst = (currency: "USD", value: 0), supply = S, tool = S,
        step = S, totaltime = ""): JsonNode =
    withSchema:
        %*{
            "@type": "HowTo",
            "name": name,
            "description": desc,
            "image": image,
            "estimatedCost": cost("monetary", currency = cst.currency, value = cst.value),
            "supply": supply,
            "tool": tool,
            "step": step,
            # https://en.wikipedia.org/wiki/ISO_8601#Durations
            "totalTime": ""
            }

proc logo(tp = "Organization", url, logo: auto, props = J): JsonNode =
    let data = withSchema:
        %*{
            "@type": tp,
            "url": url,
            "logo": logo
            }
    setProps
    data

proc ratingprop(value, best, count: auto): (string, JsonNode) =
    ("aggregateRating", %*{
        "@type": "AggregateRating",
        "ratingValue": value,
        "bestRating": best,
        "ratingCount": count})

proc movie(url, name: auto, image = "", created = "", director = "", rating = "",
        review_author = "", review = "", props = J): JsonNode =
    let data = %*{
        "@type": "Movie",
        "url": url,
        "name": name,
        "image": image,
        "dateCreated": created,
        "director": {
            "@type": "Person",
            "name": director, },
        "review": {
            "@type": "Review",
            "reviewRating": {
                "@type": "Rating",
                "ratingValue": rating, },
            "author": {
                "type": "Person",
                "name": review_author
        },
            "reviewBody": review, }
    }
    setProps
    data

proc itemslist(itms: auto): JsonNode =
    withSchema:
        %*{
            "@type": "ItemList",
            "itemListElement": itms
            }

proc review(name, rating = "", author = "", review = "", org: Organization = OG, item_props = ST,
        props = J): JsonNode =
    # let itemList = collect(for (p, v) in item_props: (p, v))
    let data = withSchema:
        %*{
            "@type": "Review",
            # "itemReviewed": itemList,
            "reviewRating": {
                "@type": "Rating",
                "ratingvalue": rating,
                },
            "name": name,
            "author": {
                "@type": "Person",
                "name": author
                },
            "reviewBody": review,
            "publisher": orgschema(org)
        }
    setProps
    data

proc searchaction(url, tpl, query: auto, props = J): JsonNode =
    let data = withSchema:
        %*{
            "@type": "WebSite",
            "url": url,
            "potentialAction": {
                "@type": "SearchAction",
                "target": {
                    "@type": "EntryPoint",
                    "urlTemplate": tpl, },
                "query-input": ("required " & query)
            }
            }
    setProps
    data

proc speakable[T](name, url: string, css: seq[T]): JsonNode =
    withSchema:
        %* {
            "@type": "WebPage",
            "name": name,
            "speakable": {
                "@type": "SpeakableSpecification",
                "cssSelector": css
            },
            "url": url
            }

proc pubevents(events: seq[(string, string)]): JsonNode =
    let ev = collect:
        for (start_date, end_date) in events:
            {
                "@type": "BroadcastEvent",
                "isLiveBroadcast": true,
                "startDate": start_date,
                "endDate": end_date
                }
    %ev

proc video(name, url: auto, desc = "", duration = "", embed = "",
            expire = "", regions = "", views="", thumbnail = "", date = "", pubevents = J): JsonNode =
    withSchema:
        %*{
            "@type": "VideoObject",
            "contentURL": url,
            "description": desc,
            "duration": duration,
            "embedURL": embed,
            "expires": expire,
            "regionsAllowed": regions,
            "interactionStatistic": {
                "@type": "InteractionCounter",
                "interactionType": {"@type": "WatchAction"},
                "userInteractionCount": views,
            },
            "name": name,
            "thumbnailUrl": thumbnail,
            "uploadDate": date,
            "publication": pubevents
            }

proc initLDJ*() =
    jsonCache = initTable[int, JsonNode]()
    EMPTY_DATE = dateTime(0, Month(1), 1)
    J = JsonNode()
    S = @[]
    ST= @[]
    ldjElement = newVNode(VNodeKind.script)
    ldjElement.setAttr("type", "application/ld+json")
    OG = initOrganization()

initLDJ()
# when isMainModule:
#     let
#         url = $WEBSITE_URL
#         auth = "fra"
#         year = 2022
#         pls = {"asd": 1, "pls": 2}
    # echo video("ok", "url", views="nice")
    # echo place()
    # echo "ok"
    # for k, v in pls.items:
    #     echo k, " v: ", v
    # echo website(url, author, year)
