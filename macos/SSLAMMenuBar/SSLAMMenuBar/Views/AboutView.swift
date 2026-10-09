import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "ear.and.waveform")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 8)

            Text("SSLAM Menu Bar")
                .font(.title2.bold())

            Text("Local audio event detection UI for macOS.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Link("SSLAM (original project)", destination: URL(string: "https://github.com/ta012/SSLAM")!)
                Link("SSLAM_AS2M_Finetuned checkpoint", destination: URL(string: "https://huggingface.co/ta012/SSLAM_AS2M_Finetuned")!)
                Link("AudioSet label metadata", destination: URL(string: "https://github.com/IBM/audioset-classification/blob/master/audioset_classify/metadata/class_labels_indices.csv")!)
            }
            .font(.caption)
            .padding(.top, 4)

            Text("Mock detection mode — no microphone or model loaded.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 360)
    }
}
