import os, streams, parsexml, strutils, chronos

import topics, pyutils
waitFor syncTopics()
let arts = waitfor topicArticles("mini")
echo arts[0]
