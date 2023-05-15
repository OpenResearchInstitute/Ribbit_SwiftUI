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

class MeasureRate {
	var startTime : UInt64 = 0
	var samplesTotal : UInt64 = 0
	func printRate(_ count : Int, _ name : String) {
		let now = DispatchTime.now().uptimeNanoseconds
		let diff = now - startTime
		samplesTotal += UInt64(count)
		if diff > 1_000_000_000 {
			let n = samplesTotal
			if startTime > 0 {
				DispatchQueue.main.async {
					let rate = (n * 1_000_000_000) / diff
					print("\(name) rate: \(rate) Hz")
				}
			}
			startTime = now
			samplesTotal = 0
		}
	}
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
	@State var nodesAttached = false
	func setupNodes() {
		if nodesAttached {
			return
		}
		nodesAttached = true
		let measureRecording = MeasureRate()
		let measureResampling = MeasureRate()
		let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
		let inputFormat = engine.inputNode.outputFormat(forBus: 0)
		let converter = AVAudioConverter(from: inputFormat, to: desiredFormat)!
		let resampled = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: AVAudioFrameCount(desiredFormat.sampleRate))!
		print("input rate: \(inputFormat.sampleRate)")
		let sink = AVAudioSinkNode { _, count, list -> OSStatus in
			measureRecording.printRate(Int(count), "recording")
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
			measureResampling.printRate(Int(resampled.frameLength), "resampled")
			return noErr
		}
		engine.attach(sink)
		engine.connect(engine.inputNode, to: sink, format: nil)
		let measurePlayback = MeasureRate()
		let source = AVAudioSourceNode { _, _, count, list -> OSStatus in
			measurePlayback.printRate(Int(count), "playback")
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
			print("Failed setting preferred sample rate to 8000 Hz")
		}
		do {
			try session.setActive(true)
		} catch {
			showStatus("Unable to set session active")
			return
		}
		setupNodes()
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
