import Foundation
import ASOCommands
#if os(Windows)
import WinSDK
#endif

// `aso`: the ASO Workbench engine on the command line. All logic lives in ASOCommands so it can be tested.
#if os(Windows)
// Output is UTF-8 ("·", "Δ", app names in any script); the console would read it in its legacy code page otherwise.
let consoleCodePage = GetConsoleOutputCP()
SetConsoleOutputCP(UINT(CP_UTF8))
let code = await CommandRunner.live().run(Array(CommandLine.arguments.dropFirst()))
fflush(stdout)
SetConsoleOutputCP(consoleCodePage)
exit(code)
#else
exit(await CommandRunner.live().run(Array(CommandLine.arguments.dropFirst())))
#endif
