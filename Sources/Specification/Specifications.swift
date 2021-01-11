import Foundation
import TSCBasic
import TSCUtility

import LTL
import Utils

public enum TransitionSystemType: String, Codable {
    case mealy
    case moore

    public var swapped: TransitionSystemType {
        switch self {
        case .mealy: return .moore
        case .moore: return .mealy
        }
    }

    public static let allValues: [TransitionSystemType] = [.mealy, .moore]
}

public enum SupportedFileFormats {
    case bosy
    case tlsf
}

public struct SynthesisSpecification: Codable {
    public var semantics: TransitionSystemType
    public let inputs: [String]
    public let outputs: [String]
    public let assumptions: [LTL]
    public let guarantees: [LTL]
    public let hyper: [LTL]?
    public let automaton: String?
    
    public init(semantics: TransitionSystemType, inputs: [String], outputs: [String], assumptions: [LTL], guarantees: [LTL], hyper: [LTL] = [], automaton: String? = nil) {
        self.semantics = semantics
        self.inputs = inputs
        self.outputs = outputs
        self.assumptions = assumptions
        self.guarantees = guarantees
        self.hyper = hyper
        self.automaton = automaton 
    }

    public var dualized: SynthesisSpecification {
        let dualizedLTL = !ltl
        guard !isHyper else {
            fatalError("Specifications containiung hyperproperties cannot be dualized")
        }
        return SynthesisSpecification(semantics: semantics.swapped, inputs: outputs, outputs: inputs, assumptions: [], guarantees: [dualizedLTL], hyper: [], automaton:nil)
    }

    public var ltl: LTL {
        assumptions.reduce(LTL.tt, &&) => guarantees.reduce(LTL.tt, &&)
    }

    public static func fromJson(string: String) -> SynthesisSpecification? {
        Logger.default().debug("parse JSON input file")

        let decoder = JSONDecoder()
        guard let data = string.data(using: .utf8) else {
            return nil
        }
        do {
            Logger.default().debug("parse JSON input file")
            return try decoder.decode(SynthesisSpecification.self, from: data)
        } catch {
            Logger.default().error("could not decode JSON: \(error.localizedDescription)")
            return nil
        }
    }

    public static func from(tlsf: String) -> SynthesisSpecification? {
        try? withTemporaryFile(dir: nil, prefix: "", suffix: ".tlsf", deleteOnClose: true) {
            (tempFile: TemporaryFile) throws -> SynthesisSpecification? in
            tempFile.fileHandle.write(Data(tlsf.utf8))

            do {
                let bosy_path = TSCBasic.ProcessEnv.vars["BOSY_PATH"] ?? "."
                let result = try TSCBasic.Process.popen(arguments: ["\(bosy_path)/Tools/syfco", "--format", "bosy", tempFile.path.pathString])
                return .fromJson(string: try result.utf8Output())
            } catch {
                Logger.default().error("could not transform TLSF to BoSy format using syfco")
                return nil
            }
        }
    }

    public var smv: String? {
        var smv: [String] = ["MODULE main", "\tVAR"]
        smv += (inputs + outputs).map { proposition in "\t\t\(proposition) : boolean;" }
        guard let smvLTLSpec = ltl.normalized.smv else {
            return nil
        }
        smv.append("\tLTLSPEC \(smvLTLSpec)")
        return smv.joined(separator: "\n")
    }

    public static func from(fileName: String, tlsf: Bool = false) throws -> SynthesisSpecification {
        // get file contents
        let data = try Data(contentsOf: URL(fileURLWithPath: fileName))
        if tlsf || fileName.hasSuffix(".tlsf") {
            return try from(tlsf: data)
        } else {
            return try from(data: data)
        }
    }

    public static func from(data: Data) throws -> SynthesisSpecification {
        // parse contents of `data`
        try JSONDecoder().decode(SynthesisSpecification.self, from: data)
    }

    public static func from(tlsf: Data) throws -> SynthesisSpecification {
        try withTemporaryFile(dir: nil, prefix: "", suffix: ".tlsf", deleteOnClose: true) {
            (tempFile: TemporaryFile) throws -> SynthesisSpecification in
            tempFile.fileHandle.write(tlsf)
            let bosy_path = TSCBasic.ProcessEnv.vars["BOSY_PATH"] ?? "."
            let result = try TSCBasic.Process.popen(arguments: ["\(bosy_path)/Tools/syfco", "--format", "bosy", tempFile.path.pathString])
            return try .from(data: result.utf8Output().data(using: .utf8)!)
        }
    }

    /**
     * Returns true if the specification contains at least one HyperLTL formula
     */
    public var isHyper: Bool {
        guard let hyper = self.hyper else {
            return false
        }
        return hyper.count > 0
    }

    /**
     * Returns HyperLTL formula in prenex format
     */
    public var hyperPrenex: LTL {
        precondition(isHyper)
        guard let hyper = self.hyper else {
            fatalError("no hyper specification")
        }
        guard hyper.count > 1 else {
            return hyper[0]
        }
        return LTL.application(.and, parameters: hyper).prenex
    }
}
