# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# """This example generates keyword ideas from a list of seed keywords."""


from pathlib import Path
from google.ads.googleads.client import GoogleAdsClient
from google.ads.googleads.errors import GoogleAdsException
from google.api_core.exceptions import ResourceExhausted

# Location IDs are listed here:
# https://developers.google.com/google-ads/api/reference/data/geotargets
# and they can also be retrieved using the GeoTargetConstantService as shown
# here: https://developers.google.com/google-ads/api/docs/targeting/location-targeting
_DEFAULT_LOCATION_IDS = [""]  #
# A language criterion ID. For example, specify 1000 for English. For more
# information on determining this value, see the below link:
# https://developers.google.com/google-ads/api/reference/data/codes-formats#expandable-7
_DEFAULT_LANGUAGE_ID = "1000"  # language ID for English

# Mapping of languages to location ids (countries)
LANG_LOC_IDS = {
    ("1000", "en"): ["2840", "2826"],
    ("1019", "ar"): "2682",
    ("1056", "bn"): "2356",
    ("1017", "zh-CN"): "2156",
    ("1010", "nl"): "2528",
    ("1042", "tl"): "2608",
    ("1002", "fr"): "2250",
    ("1001", "de"): "2276",
    ("1022", "el"): "2300",
    ("1023", "hi"): "2356",
    ("1004", "it"): "2380",
    ("1005", "ja"): "2392",
    ("1012", "ko"): "2410",
    ("1102", "ms"): "2458",
    ("1030", "pl"): "2616",
    ("1014", "pt"): "2076",
    ("1032", "ro"): "2642",
    # ("1031", "ru"): "2643", # russia is blocked...
    ("1003", "es"): "2724",
    ("1015", "sv"): "2752",
    ("1044", "th"): "2764",
    ("1037", "tr"): "2792",
    ("1036", "uk"): "2804",
    ("1041", "ur"): "2586",
    ("1040", "vi"): "2704",
}

from time import sleep
from typing import Union

import config as cfg
import log
import proxies_pb as pb
import translator as tr


# [START generate_keyword_ideas]
def main(client, customer_id, location_ids, language_id, keyword_texts, page_url):
    keyword_plan_idea_service = client.get_service("KeywordPlanIdeaService")
    keyword_competition_level_enum = client.enums.KeywordPlanCompetitionLevelEnum
    keyword_plan_network = (
        client.enums.KeywordPlanNetworkEnum.GOOGLE_SEARCH_AND_PARTNERS
    )
    location_rns = _map_locations_ids_to_resource_names(client, location_ids)
    language_rn = client.get_service("GoogleAdsService").language_constant_path(
        language_id
    )

    # Either keywords or a page_url are required to generate keyword ideas
    # so this raises an error if neither are provided.
    if not (keyword_texts or page_url):
        raise ValueError(
            "At least one of keywords or page URL is required, "
            "but neither was specified."
        )

    # Only one of the fields "url_seed", "keyword_seed", or
    # "keyword_and_url_seed" can be set on the request, depending on whether
    # keywords, a page_url or both were passed to this function.
    request = client.get_type("GenerateKeywordIdeasRequest")
    request.customer_id = customer_id
    request.language = language_rn
    request.geo_target_constants = location_rns
    request.include_adult_keywords = False
    request.keyword_plan_network = keyword_plan_network

    # To generate keyword ideas with only a page_url and no keywords we need
    # to initialize a UrlSeed object with the page_url as the "url" field.
    if not keyword_texts and page_url:
        request.url_seed.url = page_url

    # To generate keyword ideas with only a list of keywords and no page_url
    # we need to initialize a KeywordSeed object and set the "keywords" field
    # to be a list of StringValue objects.
    if keyword_texts and not page_url:
        request.keyword_seed.keywords.extend(keyword_texts)

    # To generate keyword ideas using both a list of keywords and a page_url we
    # need to initialize a KeywordAndUrlSeed object, setting both the "url" and
    # "keywords" fields.
    if keyword_texts and page_url:
        request.keyword_and_url_seed.url = page_url
        request.keyword_and_url_seed.keywords.extend(keyword_texts)

    keyword_ideas = keyword_plan_idea_service.generate_keyword_ideas(request=request)

    return [idea.text for idea in keyword_ideas]
    # [END generate_keyword_ideas]


def map_keywords_to_string_values(client, keyword_texts):
    keyword_protos = []
    for keyword in keyword_texts:
        string_val = client.get_type("StringValue")
        string_val.value = keyword
        keyword_protos.append(string_val)
    return keyword_protos


def _map_locations_ids_to_resource_names(client, location_ids):
    """Converts a list of location IDs to resource names.

    Args:
        client: an initialized GoogleAdsClient instance.
        location_ids: a list of location ID strings.

    Returns:
        a list of resource name strings using the given location IDs.
    """
    build_resource_name = client.get_service(
        "GeoTargetConstantService"
    ).geo_target_constant_path
    return [build_resource_name(location_id) for location_id in location_ids]


class Keywords:
    _config: Path = cfg.PROJECT_DIR / "config" / "google-ads.yml"
    _customer_id_path = cfg.PROJECT_DIR / "config" / "adwords_customer_id.txt"
    _customer_id = ""

    def __init__(self) -> None:
        if not self._config.exists():
            raise OSError(f"file not found {self._config}")
        if not self._customer_id_path.exists():
            raise OSError(f"file not found {self._customer_id_path}")
        self.client = GoogleAdsClient.load_from_storage(self._config, version="v10")
        with open(self._customer_id_path, "r") as f:
            self._customer_id = f.read()

    def suggest(
        self,
        kw: Union[list, str],
        page_url="",
        langloc=LANG_LOC_IDS,
        delay=1,
        sugs=None,
    ):
        try:
            if sugs is None:
                sugs = []
            if langloc is None:
                langloc = {("1000", "en"): []}
            for lang, loc_id in langloc.items():
                lang_id, lang_code = lang
                # print("lang: ", lang_id, " loc: ", loc_id)
                if lang_code != "en":
                    assert kw is str
                    kw_t = tr.translate(kw, to_lang=lang_code, from_lang="en")
                else:
                    kw_t = kw
                with pb.http_opts():
                    s = main(
                        self.client,
                        self._customer_id,
                        [loc_id] if isinstance(loc_id, str) else loc_id,
                        lang_id,
                        [kw_t] if kw_t is str else kw_t,
                        page_url,
                    )
                sleep(1)
                sugs.extend(s)
            return list(dict.fromkeys(sugs))  ## dedup
        except GoogleAdsException as ex:
            if isinstance(ex, ResourceExhausted):
                return self.suggest(kw, page_url, langloc, delay=delay * 2, sugs=sugs)
            log.warn(
                f'Request with ID "{ex.request_id}" failed with status '
                f'"{ex.error.code().name}" and includes the following errors:'
            )
            for error in ex.failure.errors:
                log.warn(f'\tError with message "{error.message}".')
                if error.location:
                    for field_path_element in error.location.field_path_elements:
                        log.warn(f"\t\tOn field: {field_path_element.field_name}")
            return list(dict.fromkeys(sugs))  ## dedup
