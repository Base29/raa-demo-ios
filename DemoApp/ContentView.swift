import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var viewModel = MicInputViewModel()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Mic Input Foundation Demo")
                .font(.title)
                .padding()
            
            // Configuration Labels
            VStack(alignment: .leading, spacing: 10) {
                LabelRow(title: "Sample Rate:", value: "\(viewModel.sampleRate) Hz")
                LabelRow(title: "Channels:", value: "\(viewModel.channels)")
                LabelRow(title: "Buffer Size:", value: "\(viewModel.bufferSize)")
                LabelRow(title: "Total Frames Received:", value: "\(viewModel.totalFramesReceived)")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(10)
            
            // Permission Status
            if viewModel.permissionDenied {
                Text("Microphone permission denied. Please grant access in Settings.")
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            
            // Control Buttons
            HStack(spacing: 20) {
                Button(action: {
                    viewModel.startCapture()
                }) {
                    Text("Start")
                        .frame(width: 100, height: 44)
                        .background(viewModel.isRunning || viewModel.permissionDenied ? Color.gray : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(viewModel.isRunning || viewModel.permissionDenied)
                
                Button(action: {
                    viewModel.stopCapture()
                }) {
                    Text("Stop")
                        .frame(width: 100, height: 44)
                        .background(viewModel.isRunning ? Color.red : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .disabled(!viewModel.isRunning)
            }
            .padding()
            
            Spacer()
        }
        .padding()
        .onAppear {
            viewModel.checkPermission()
        }
    }
}

struct LabelRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .fontWeight(.semibold)
            Spacer()
            Text(value)
                .foregroundColor(.blue)
        }
    }
}
