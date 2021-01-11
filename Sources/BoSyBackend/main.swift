import Automata
import BoundedSynthesis
import Foundation
import LTL
import Specification
import TransitionSystem
import Utils

import CAiger

var options = BoSyOptions()

do {
    try options.parseCommandLine()
} catch {
    print(error)
    options.printHelp()
    exit(1)
}

let json: String

let parseTimer = options.statistics?.startTimer(phase: .parsing)

var fileFormat: SupportedFileFormats = .bosy

if let specificationFile = options.specificationFile {
    Logger.default().debug("reading from file \"\(specificationFile)\"")
    guard let specficationString = try? String(contentsOfFile: specificationFile, encoding: String.Encoding.utf8) else {
        print("error: cannot read input file \(specificationFile)")
        exit(1)
    }
    json = specficationString
    if specificationFile.hasSuffix(".tlsf") {
        fileFormat = .tlsf
    }
} else {
    // Read from stdin
    let standardInput = FileHandle.standardInput

    Logger.default().debug("reading from stdin")

    let input = StreamHelper.readAllAvailableData(from: standardInput)

    guard let specficationString = String(data: input, encoding: String.Encoding.utf8) else {
        print("error: cannot read input from stdin")
        exit(1)
    }
    json = specficationString
}

var specification: SynthesisSpecification

switch fileFormat {
case .bosy:
    guard let s = SynthesisSpecification.fromJson(string: json) else {
        print("error: cannot parse specification")
        exit(1)
    }
    specification = s
case .tlsf:
    guard let s = SynthesisSpecification.from(tlsf: json) else {
        print("error: cannot parse specification")
        exit(1)
    }
    specification = s
}

parseTimer?.stop()

// override semantics if given as command line argument
if let semantics = options.semantics {
    specification.semantics = semantics
}

// Logger.default().info("inputs: \(specification.inputs), outputs: \(specification.outputs)")
// Logger.default().info("assumptions: \(specification.assumptions), guarantees: \(specification.guarantees)")

private func buildAutomaton(player: Player) -> CoBüchiAutomaton? {
    Logger.default().debug("start building automaton for player \(player)")

    if specification.automaton != nil {
        Logger.default().debug("reading in specification automaton from \(specification.automaton!)")    

        guard let automaton = try? CoBüchiAutomaton.from(ltl: LTL.ff, automaton: specification.automaton, using: options.converter)
        else {
            Logger.default().error("could not construct automaton")
            return nil
        }

        Logger.default().info("automaton contains \(automaton.states.count) states")
        return automaton 
    }
    else // look at LTL specification
    if options.monolithic || player == .environment || specification.assumptions.count > 0 {
        let assumption: LTL = specification.assumptions.reduce(LTL.tt, &&)
        let guarantee: LTL = specification.guarantees.reduce(LTL.tt, &&)

        let ltlSpec: LTL
        if player == .system {
            ltlSpec = specification.assumptions.count == 0 ? !guarantee : !(assumption => guarantee)
        } else {
            assert(player == .environment)
            ltlSpec = specification.assumptions.count == 0 ? guarantee : assumption => guarantee
        }

        let automatonTimer = options.statistics?.startTimer(phase: .ltl2automaton)
        guard let automaton = try? CoBüchiAutomaton.from(ltl: ltlSpec, automaton: nil, using: options.converter) else {
            Logger.default().error("could not construct automaton")
            return nil
        }
        automatonTimer?.stop()
        Logger.default().debug("building automaton for player \(player) succeeded")
        return automaton
    } else {
        assert(specification.assumptions.count == 0)
        assert(player == .system)

        var automata: [CoBüchiAutomaton] = []
        for guarantee in specification.guarantees {
            let automatonTimer = options.statistics?.startTimer(phase: .ltl2automaton)
            guard let automaton = try? CoBüchiAutomaton.from(ltl: guarantee, automaton: nil, using: options.converter) else {
                Logger.default().error("could not construct automaton")
                return nil
            }
            automatonTimer?.stop()
            automata.append(automaton)
        }

        Logger.default().debug("building automaton for player \(player) succeeded")

        return CoBüchiAutomaton(automata: automata)
    }
}

func search(strategy: SearchStrategy, player: Player, synthesize: Bool) -> (() -> Void) {
    Logger.default().debug("start search strategy (strategy: \"\(strategy)\", player: \"\(player)\", synthesize: \(synthesize))")
    return {
        guard let automaton = buildAutomaton(player: player) else {
            return
        }

        Logger.default().info("automaton contains \(automaton.states.count) states")

        let synthesize = synthesize && !(player == .environment && options.syntcomp2017rules)

        var search = SolutionSearch(options: options, specification: specification, automaton: automaton, searchStrategy: strategy, player: player, backend: options.backend, initialBound: options.minBound, synthesize: synthesize)

        if search.hasSolution(limit: options.maxBound ?? Int.max) {
            if !synthesize {
                player == .system ? print("result: realizable") : print("result: unrealizable")
                return
            }
            guard let solution = search.getSolution() else {
                Logger.default().error("could not construct solution")
                return
            }
            switch options.target {
            case .aiger:
                guard let aiger_solution = (solution as? AigerRepresentable)?.aiger else {
                    Logger.default().error("could not encode solution as AIGER")
                    return
                }
                let minimized = aiger_solution.minimized
                aiger_write_to_file(minimized, aiger_ascii_mode, stdout)
                player == .system ? print("result: realizable") : print("result: unrealizable")
            case .dot:
                guard let dot = (solution as? DotRepresentable)?.dot else {
                    Logger.default().error("could not encode solution as dot")
                    return
                }
                print(dot)
            case .dotTopology:
                guard let dot = (solution as? DotRepresentable)?.dotTopology else {
                    Logger.default().error("could not encode solution as dot")
                    return
                }
                print(dot)
            case .smv:
                guard let smv = (solution as? SmvRepresentable)?.smv else {
                    Logger.default().error("could not encode solution as SMV")
                    return
                }
                print(smv)
            case .verilog:
                guard let verilog = (solution as? VerilogRepresentable)?.verilog else {
                    Logger.default().error("could not encode solution as Verilog")
                    return
                }
                print(verilog)
            case .all:
                var result: [String: String] = [:]
                guard let dotSolution = solution as? DotRepresentable else {
                    Logger.default().error("could not encode solution as dot")
                    return
                }
                result["dot"] = dotSolution.dot
                result["dot-topology"] = dotSolution.dotTopology
                guard let smv = (solution as? SmvRepresentable)?.smv else {
                    Logger.default().error("could not encode solution as SMV")
                    return
                }
                result["smv"] = smv
                guard let verilog = (solution as? VerilogRepresentable)?.verilog else {
                    Logger.default().error("could not encode solution as Verilog")
                    return
                }
                result["verilog"] = verilog
                guard let jsonData = try? JSONSerialization.data(withJSONObject: result) else {
                    Logger.default().error("could not encode solution JSON")
                    return
                }
                guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                    Logger.default().error("could not encode solution JSON")
                    return
                }
                print(jsonString)
            }

            return
        }
        print("result: unknown")
    }
}

// search(strategy: options.searchStrategy, player: .system, synthesize: options.synthesize)()

let condition = NSCondition()
var finished = false

let searchSystem = search(strategy: options.searchStrategy, player: .system, synthesize: options.synthesize)
let searchEnvironment = search(strategy: options.searchStrategy, player: .environment, synthesize: options.synthesize)

let doSearchSystem = (specification.automaton != nil) || options.player.contains(.system)
let doSearchEnvironment = (specification.automaton == nil) && options.player.contains(.environment)


#if os(Linux)
    let thread1 = Thread {
        searchSystem()
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    let thread2 = Thread {
        searchEnvironment()
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    if doSearchSystem {
        thread1.start()
    }

    if doSearchEnvironment {
        thread2.start()
    }

#else
    class ThreadedExecution: Thread {
        let function: () -> Void

        init(function: @escaping (() -> Void)) {
            self.function = function
        }

        override func main() {
            function()
            condition.lock()
            finished = true
            condition.broadcast()
            condition.unlock()
        }
    }

    if doSearchSystem {
        ThreadedExecution(function: searchSystem).start()
    }

    if doSearchEnvironment {
        ThreadedExecution(function: searchEnvironment).start()
    }
#endif

condition.lock()
while !finished {
    condition.wait()
}

condition.unlock()

if let statistics = options.statistics {
    print(statistics.description)
}
