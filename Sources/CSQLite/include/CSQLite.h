#ifndef CSQLITE_H
#define CSQLITE_H

// The platform's own SQLite, so the engine needs no package dependency.
// Windows 10 and later ship it as winsqlite3, with the header in the Windows SDK.
#if defined(_WIN32)
#include <winsqlite/winsqlite3.h>
#else
#include <sqlite3.h>
#endif

#endif
