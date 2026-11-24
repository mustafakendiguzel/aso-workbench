import Foundation
import ASOCommands

// `aso`: the ASO Workbench engine on the command line. All logic lives in ASOCommands so it can be tested.
exit(await CommandRunner.live().run(Array(CommandLine.arguments.dropFirst())))
