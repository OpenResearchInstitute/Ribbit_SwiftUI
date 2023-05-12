//
//  RibbitApp.swift
//  Ribbit
//
//  Created by Ahmet Inan on 3/6/23.
//

import SwiftUI

@main
struct RibbitApp: App {
	@StateObject var state = MyState()
	var body: some Scene {
		WindowGroup {
			ContentView(state: state)
		}
	}
}
