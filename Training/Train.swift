// Trains the talk detector on the clips from MakeDataset and checks it on the held-out broadcasts.
//
// Usage: train <dataset folder> <model output path>
//
// Transfer learning: Apple's sound feature extractor, already trained on a great deal of audio, turns each second of
// sound into a description, and only a small layer on top learns which descriptions mean "the announcer is talking".
// That's why it trains in minutes on a laptop.

import CreateML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: train <dataset folder> <model output path>") }
let dataset = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

let started = Date()
let parameters = MLSoundClassifier.ModelParameters(
    validation: .split(strategy: .automatic),
    maxIterations: 60,
    overlapFactor: 0.5,
    algorithm: .transferLearning(featureExtractor: .audioFeaturePrint(), classifier: .multilayerPerceptron(layerSizes: [128]))
)
let classifier = try MLSoundClassifier(trainingData: .labeledDirectories(at: dataset.appending(path: "train")), parameters: parameters)
print(String(format: "trained in %.0f s", Date().timeIntervalSince(started)))
print(String(format: "training accuracy   %.1f%%", (1 - classifier.trainingMetrics.classificationError) * 100))
print(String(format: "validation accuracy %.1f%%", (1 - classifier.validationMetrics.classificationError) * 100))

let test = classifier.evaluation(on: .labeledDirectories(at: dataset.appending(path: "test")))
print(String(format: "held-out broadcasts %.1f%%", (1 - test.classificationError) * 100))
print(test.confusion)

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try classifier.write(to: output, metadata: MLModelMetadata(
    author: "ABS Radio Maker",
    shortDescription: "Tells whether the announcer is talking, even over background music. Labels: talk, quiet.",
    version: "1"
))
print("wrote", output.path)
