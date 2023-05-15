//
//  ContentView.swift
//  Ribbit
//
//  Created by Ahmet Inan on 3/6/23.
//

import SwiftUI
import AVFoundation

class MyState: ObservableObject {
	@Published var status = "status"
	@Published var composerLeft = "244 bytes left"
	@Published var disableTransmit = false
	@Published var composerText = "Hello World!" {
		didSet {
			let bytes = composerText.withCString { strlen($0) }
			if bytes <= 256 {
				let left = 256 - bytes
				composerLeft = "\(left) byte\(left == 1 ? "" : "s") left"
				disableTransmit = bytes == 0
			} else {
				let over = bytes - 256
				composerLeft = "\(over) byte\(over == 1 ? "" : "s") over capacity"
				disableTransmit = true
			}
		}
	}
	@Published var showComposer = false
}

struct ContentView: View {
	let session = AVAudioSession()
	let engine = AVAudioEngine()
	func checkMicrophonePermission() -> Bool {
		switch session.recordPermission {
		case .granted:
			return true
		case .denied:
			return false
		case .undetermined:
			session.requestRecordPermission { granted in
				DispatchQueue.main.async { restartEngine() }
			}
			return false
		@unknown default:
			return false
		}
	}
	func showStatus(_ status : String) {
		state.status = status
	}
	@State var listening = true
	@State var nodesAttached = false
	func setupNodes() {
		if nodesAttached {
			return
		}
		nodesAttached = true
		let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
		let inputFormat = engine.inputNode.outputFormat(forBus: 0)
		let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)!
		let resampled = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: AVAudioFrameCount(desiredFormat.sampleRate))!
		let sink = AVAudioSinkNode { _, _, list -> OSStatus in
			var haveData = true
			var error: NSError? = nil
			converter.convert(to: resampled, error: &error) { _, inputStatus in
				if haveData {
					haveData = false
					inputStatus.pointee = .haveData
					return AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: list)
				}
				inputStatus.pointee = .noDataNow
				return nil
			}
			if listening && feedDecoder(resampled.floatChannelData![0], Int32(resampled.frameLength)) {
				DispatchQueue.main.async {
					var payload = [CChar](repeating: 0, count: 257)
					let result = fetchDecoder(&payload)
					if result < 0 {
						showStatus("Decoding failed")
					} else {
						var message = "Payload unknown"
						if let msg = String(cString: payload, encoding: .utf8) {
							message = msg.trimmingCharacters(in: .whitespacesAndNewlines)
						}
						showStatus("\(message)\n\n(\(result) bit flip\(result == 1 ? "" : "s") corrected)")
					}
				}
			}
			return noErr
		}
		engine.attach(sink)
		engine.connect(engine.inputNode, to: sink, format: nil)
		let source = AVAudioSourceNode { _, _, count, list -> OSStatus in
			if !listening {
				let channels = UnsafeMutableAudioBufferListPointer(list)
				let first: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(channels[0])
				if readEncoder(first.baseAddress, Int32(count)) {
					listening = true
					DispatchQueue.main.async {
						showStatus("Listening")
					}
				}
			}
			return noErr
		}
		engine.attach(source)
		engine.connect(source, to: engine.mainMixerNode, format: desiredFormat)
	}
	func startEngine() {
		if !session.isInputAvailable {
			showStatus("No audio input available")
			return
		}
		if !checkMicrophonePermission() {
			showStatus("No permission to open microphone")
			return
		}
		do {
			try session.setCategory(.playAndRecord, mode: .measurement, options: .defaultToSpeaker)
		} catch {
			showStatus("Unable to set session category")
			return
		}
		do {
			try session.setPreferredSampleRate(8000)
		} catch {
			showStatus("Unable to set preferred sample rate")
			return
		}
		do {
			try session.setActive(true)
		} catch {
			showStatus("Unable to set session active")
			return
		}
		setupNodes()
		if !createEncoder() {
			showStatus("Unable to create encoder")
			return
		}
		if !createDecoder() {
			showStatus("Unable to create decoder")
			return
		}
		do {
			try engine.start()
		} catch {
			showStatus("Unable to start audio engine")
			return
		}
		showStatus("Listening")
	}
	func stopEngine() {
		engine.stop()
		showStatus("Stopped")
	}
	@State var debounceTimer: Timer?
	func restartEngine() {
		stopEngine()
		debounceTimer?.invalidate()
		debounceTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
			startEngine()
		}
	}
	func handleInterruption(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
		      let interruptionTypeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
		      let interruptionType = AVAudioSession.InterruptionType(rawValue: interruptionTypeValue) else { return }
		switch interruptionType {
		case .began:
			stopEngine()
		case .ended:
			guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
			let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
			if options.contains(.shouldResume) {
				restartEngine()
			}
		@unknown default:
			break
		}
	}
	func handleRouteChange(_ notification: Notification) {
		guard let userInfo = notification.userInfo,
		      let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
		      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
		if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
			restartEngine()
		}
	}
	func transmitMessage(_ text : String) {
		var payload = [CChar](repeating: 0, count: 256)
		text.withCString { _ = strncpy(&payload, $0, 256) }
		initEncoder(&payload)
		listening = false
		showStatus("Transmitting")
	}
	@ObservedObject var state: MyState
	var body: some View {
		VStack {
			HStack {
				Text("Ribbit")
				Spacer()
				Button(action: {
					state.showComposer = true
				}) {
					Image(systemName: "message")
				}
			}
			Spacer()
			Text(state.status)
			Spacer()
		}
		.sheet(isPresented: $state.showComposer) {
			VStack {
				Text("Compose Message").fontWeight(.bold)
				TextEditor(text: $state.composerText)
				Text(state.composerLeft)
				HStack {
					Button(action: {
						state.showComposer = false
					}) {
						Text("BACK")
					}
					Spacer()
					Button(action: {
						state.showComposer = false
						transmitMessage(state.composerText)
					}) {
						Text("TRANSMIT")
					}
					.disabled(state.disableTransmit)
				}
			}
			.padding()
		}
		.padding()
		.onAppear() {
			NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil, using: handleInterruption(_:))
			NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: handleRouteChange(_:))
			restartEngine()
		}
	}
}
