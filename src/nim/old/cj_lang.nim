import std/tables

const CJ_LANGS = {
  "English" : 9,
  "Spanish" : 29,
  "French" : 11,
  "German" : 12,
  "Swedish" : 30,
  "Arabic" : 1,
  "Bengali" : 2,
  "Bulgarian" : 3,
  "Mandarin Chinese": 4,
  "Chinese" : 4,
  "Chinese (Simplified)" : 4,
  "Chinese (Traditional)" : 5,
  "Czech" : 6,
  "Danish" : 7,
  "Dutch" : 8,
  "Finnish" : 10,
  "Greek" : 13,
  "Hebrew" : 14,
  "Hindi" : 15,
  "Hungarian" : 16,
  "Indonesian" : 17,
  "Italian" : 18,
  "Japanese" : 19,
  "Korean" : 20,
  "Malay" : 21,
  "Norwegian" : 22,
  "Persian" : 23,
  "Polish" : 24,
  "Portuguese" : 25,
  "Romanian" : 26,
  "Russian" : 27,
  "Slovenian" : 28,
  "Tamil" : 31,
  "Thai" : 32,
  "Turkish" : 33,
  "Ukrainian" : 34,
  "Vietnamese" : 35,
}.toTable

proc cjLangCode*(lang: string, def = 9): int = CJ_LANGS.getOrDefault(lang, def)
