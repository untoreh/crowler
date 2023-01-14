import leveldb
import ../src/nim/data

import os
# let pd = os.getenv("PROJECT_DIR", "")
# os.putenv("LD_LIBRARY_PATH", pd / "lib")

discard init(LockDB, "/tmp/watdb")

echo "test.nim:8"
