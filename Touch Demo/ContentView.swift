//
//  ContentView.swift
//  Touch Demo
//
//  Created by Carl Allen on 8/22/26.
//

import SwiftUI

struct ContentView: View {
    @State private var mode: TouchMode = .buggy
    @State private var clearToken = 0

    var body: some View {
        VStack(spacing: 14) {
            Picker("Touch handling", selection: $mode) {
                ForEach(TouchMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text(mode.headline)
                    .font(.subheadline.weight(.semibold))
                Text(mode.instructions)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TraceCanvas(mode: mode, clearToken: clearToken)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color(.separator), lineWidth: 1)
                )

            HStack(spacing: 16) {
                Label("Tracing", systemImage: "circle.fill")
                    .foregroundStyle(.green)
                Label("Ignored", systemImage: "circle.fill")
                    .foregroundStyle(.gray)
                Spacer()
                Button("Clear", systemImage: "trash") {
                    clearToken += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .font(.footnote)
        }
        .padding()
        .onChange(of: mode) {
            clearToken += 1
        }
    }
}

#Preview {
    ContentView()
}
