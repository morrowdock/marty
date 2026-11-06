// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The engine's building blocks below components: shapes, joints, drives and constraints.
///
/// The engine does not publish these lists as an API, so Marty keeps them here, taken from docs/SOLID-3D.md at the
/// pinned commit. Tests hold them to the engine: every example must pass `check`, every required key must be named
/// when it is missing, and every optional key must be known to the parser.
public struct MartyPrimitive: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case shape, joint, drive, constraint
        var plural: String { rawValue + "s" }
    }
    public let id: String
    public let kind: Kind
    public let about: String
    public let required: [String]
    public let optional: [String]
    /// A complete assembly document that the engine accepts.
    public let example: String

    func summary(full: Bool) -> [String: Any] {
        var out: [String: Any] = ["id": id, "kind": kind.rawValue, "about": about, "required": required, "optional": optional]
        if full, let data = example.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            out["example"] = object
        }
        return out
    }

    static func doc(_ title: String, _ parts: String, constraints: String? = nil) -> String {
        #"{"v":1,"kind":"assembly","title":"\#(title)","units":"mm","parts":[\#(parts)]"#
            + (constraints.map { #","constraints":[\#($0)]"# } ?? "") + "}"
    }

    static func shape(_ id: String, _ about: String, _ req: [String], _ opt: [String], _ body: String) -> MartyPrimitive {
        MartyPrimitive(id: id, kind: .shape, about: about, required: req, optional: opt + ["at", "rot"],
                       example: doc("One \(id)", #"{"id":"p","name":"Example \#(id)","material":"brushedSteel","shape":{"\#(id)":\#(body)}}"#))
    }

    static let spurPair = #"{"id":"pinion","name":"Pinion","material":"brass","shape":{"gear":{"teeth":12,"module":2,"width":10,"bore":4}},"joint":{"revolute":[0,0,1]},"drive":{"input":1}},{"id":"wheel","name":"Wheel","material":"brushedSteel","at":[48,0,0],"shape":{"gear":{"teeth":36,"module":2,"width":10,"bore":6}},"joint":{"revolute":[0,0,1]}}"#
    static let crank = #"{"id":"crank","name":"Crank","material":"brushedSteel","shape":[{"shaft":{"radius":6,"length":16,"z0":-10}},{"box":{"size":[30,12,6],"at":[9,0,-3]}}],"joint":{"revolute":[0,0,1]},"drive":{"input":1}}"#

    public static let all: [MartyPrimitive] = [
        shape("gear", "External spur gear about local Z. Pitch diameter = module × teeth.",
              ["teeth", "module", "width"], ["bore", "keyway", "z0", "pressureAngle", "chamfer", "backlash"],
              #"{"teeth":24,"module":2,"width":10,"bore":6}"#),
        shape("ringGear", "Internal ring gear about local Z. `outer` is the outside radius of the ring.",
              ["teeth", "module", "width", "outer"], ["z0", "pressureAngle", "chamfer", "backlash"],
              #"{"teeth":60,"module":2,"width":12,"outer":70}"#),
        shape("shaft", "Solid cylinder along local Z from z0 to z0 + length.",
              ["radius", "length"], ["z0", "chamfer"], #"{"radius":4,"length":40}"#),
        shape("tube", "Hollow cylinder along local Z.",
              ["inner", "outer", "length"], ["z0", "chamfer"], #"{"inner":4,"outer":6,"length":30}"#),
        shape("box", "Box centred on the part origin. `size` is [x, y, z].",
              ["size"], ["chamfer"], #"{"size":[40,20,6]}"#),
        shape("hex", "Hexagonal prism along local Z (a nut or bolt head).",
              ["acrossFlats", "length"], ["z0", "chamfer"], #"{"acrossFlats":10,"length":6}"#),
        shape("plate", "Disc in the XY plane with round holes [x, y, radius].",
              ["radius", "thickness"], ["z0", "chamfer", "holes"], #"{"radius":30,"thickness":4,"holes":[[15,0,3],[-15,0,3]]}"#),
        shape("carrier", "Planet carrier: hub, arms and bosses with a smooth union.",
              ["arms", "radius", "hub", "boss", "armWidth", "thickness"], ["z0", "chamfer", "blend"],
              #"{"arms":3,"radius":30,"hub":10,"boss":6,"armWidth":8,"thickness":5}"#),
        shape("extrudedProfile", "A closed 2D outline [[x, y], ...] (optional holes) extruded along local Z by `depth`.",
              ["points", "depth"], ["holes", "z0", "chamfer"], #"{"points":[[0,0],[40,0],[40,10],[0,10]],"depth":5}"#),
        shape("revolvedProfile", "A profile [[radius, z], ...] turned about local Z. Open profiles start and end on the axis (radius 0); `closed` makes a wall. `sweep` and `start` (degrees) give a capped partial revolve for cutaways.",
              ["points"], ["closed", "sweep", "start"], #"{"points":[[0,0],[10,0],[10,20],[0,20]]}"#),
        shape("blade", "One airfoil along +X from `root` to `root + span`. Section angle = pitch + twist × t.",
              ["span", "chord"], ["thickness", "twist", "pitch", "root", "tipChord", "camber", "camberPosition"],
              #"{"span":80,"chord":20,"root":10,"pitch":-30,"twist":20}"#),
        shape("bladeRow", "A ring of `count` blades around local Z on a hub of radius `root` (fan or compressor rotor). The leading edge points to -Z.",
              ["count", "span", "chord", "root"],
              ["z", "thickness", "stagger", "twist", "tipChord", "camber", "camberPosition", "phase", "sections", "chordSamples"],
              #"{"count":12,"span":40,"chord":15,"root":30}"#),

        MartyPrimitive(id: "revolute", kind: .joint, about: "The part turns about an axis [x, y, z] in its parent frame: \"joint\": {\"revolute\": [0, 0, 1]}.",
                       required: ["axis"], optional: [],
                       example: doc("One turning shaft", #"{"id":"s","name":"Shaft","material":"brushedSteel","shape":{"shaft":{"radius":4,"length":40}},"joint":{"revolute":[0,0,1]},"drive":{"input":1}}"#)),
        MartyPrimitive(id: "prismatic", kind: .joint, about: "The part slides along an axis [x, y, z]: \"joint\": {\"prismatic\": [1, 0, 0]}.",
                       required: ["axis"], optional: [],
                       example: doc("One sliding block", #"{"id":"b","name":"Block","material":"aluminum","shape":{"box":{"size":[20,10,10]}},"joint":{"prismatic":[1,0,0]},"drive":{"input":5}}"#)),

        MartyPrimitive(id: "input", kind: .drive, about: "The joint follows the input parameter times a scale: \"drive\": {\"input\": 1}. A negative scale turns the other way.",
                       required: ["scale"], optional: [],
                       example: doc("One driven shaft", #"{"id":"s","name":"Shaft","material":"brushedSteel","shape":{"shaft":{"radius":4,"length":40}},"joint":{"revolute":[0,0,1]},"drive":{"input":1}}"#)),
        MartyPrimitive(id: "follow", kind: .drive, about: "The joint follows another part's joint times `ratio` (no gear check; use gearMesh for gears).",
                       required: ["source", "ratio"], optional: [],
                       example: doc("Two linked shafts", #"{"id":"a","name":"Driver","material":"brushedSteel","shape":{"shaft":{"radius":4,"length":40}},"joint":{"revolute":[0,0,1]},"drive":{"input":1}},{"id":"b","name":"Follower","material":"brass","at":[30,0,0],"shape":{"shaft":{"radius":4,"length":40}},"joint":{"revolute":[0,0,1]},"drive":{"follow":{"source":"a","ratio":-0.5}}}"#)),
        MartyPrimitive(id: "crankSlider", kind: .drive, about: "A prismatic piston driven by a crank of `radius` through a rod of length `rod` (rod > radius). Stroke = 2 × radius.",
                       required: ["crank", "radius", "rod"], optional: [],
                       example: doc("Slider-crank", crank + #",{"id":"piston","name":"Piston","material":"aluminum","shape":{"shaft":{"radius":14,"length":24,"z0":-12,"rot":[0,1,0,90]}},"joint":{"prismatic":[1,0,0]},"drive":{"crankSlider":{"crank":"crank","radius":18,"rod":62}}}"#)),
        MartyPrimitive(id: "crankRod", kind: .drive, about: "The connecting rod's angle for a slider-crank; the rod is a child of the piston with a revolute joint.",
                       required: ["crank", "radius", "rod"], optional: [],
                       example: doc("Slider-crank with rod", crank + #",{"id":"piston","name":"Piston","material":"aluminum","shape":{"shaft":{"radius":14,"length":24,"z0":-12,"rot":[0,1,0,90]}},"joint":{"prismatic":[1,0,0]},"drive":{"crankSlider":{"crank":"crank","radius":18,"rod":62}}},{"id":"rod","name":"Rod","parent":"piston","material":"anodized.orange","shape":{"box":{"size":[62,8,4],"at":[-31,0,5]}},"joint":{"revolute":[0,0,1]},"drive":{"crankRod":{"crank":"crank","radius":18,"rod":62}}}"#)),

        MartyPrimitive(id: "gearMesh", kind: .constraint, about: "Two gears mesh. The engine checks module, pressure angle, axes and centre distance, phases the teeth and solves the ratio. Name the `carrier` for planets.",
                       required: ["a", "b"], optional: ["carrier"],
                       example: doc("Spur gear pair", spurPair, constraints: #"{"gearMesh":{"a":"pinion","b":"wheel"}}"#)),
        MartyPrimitive(id: "fixed", kind: .constraint, about: "Hold a part's joint still: {\"fixed\": \"ring\"}. A part with no joint is already fixed.",
                       required: ["part"], optional: [],
                       example: doc("Planetary set with the ring held", #"{"id":"sun","name":"Sun","material":"brass","shape":{"gear":{"teeth":24,"module":2,"width":10,"bore":6}},"joint":{"revolute":[0,0,1]},"drive":{"input":1}},{"id":"ring","name":"Ring","material":"darkSteel","shape":{"ringGear":{"teeth":60,"module":2,"width":10,"outer":70}},"joint":{"revolute":[0,0,1]}},{"id":"carrier","name":"Carrier","material":"anodized.blue","shape":{"carrier":{"arms":1,"radius":42,"hub":10,"boss":6,"armWidth":8,"thickness":4,"z0":11}},"joint":{"revolute":[0,0,1]}},{"id":"planet","name":"Planet","parent":"carrier","at":[42,0,0],"material":"brushedSteel","shape":{"gear":{"teeth":18,"module":2,"width":10}},"joint":{"revolute":[0,0,1]}}"#,
                                   constraints: #"{"gearMesh":{"a":"sun","b":"planet","carrier":"carrier"}},{"gearMesh":{"a":"ring","b":"planet","carrier":"carrier"}},{"fixed":"ring"}"#)),
    ]
}
