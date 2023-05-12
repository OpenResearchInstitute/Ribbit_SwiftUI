//
//  ContentView.swift
//  Ribbit
//
//  Created by Ahmet Inan on 3/6/23.
//

import SwiftUI

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
	}
}
