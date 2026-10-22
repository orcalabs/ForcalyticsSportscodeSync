//
//  TestView.swift
//  ForcalyticsSportscodeSync
//
//  Created by Orca Labs on 22/10/2026.
//

import AppKit
import Combine
import MenuBarExtraAccess
import SwiftUI
import UniformTypeIdentifiers

struct TestView: View {
    @AppStorage("syncRequestURL")
    private var requestURLInput = "https://api.dev.forcalytics.orcalabs.no/v1.0/live_streams/export_sportscode"

    private var requestInput: Result<URL, InputError> {
        let input = requestURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !input.isEmpty else {
            return .failure(.empty)
        }

        guard
            let url = URL(string: input),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil
        else {
            return .failure(.invalid("Invalid URL"))
        }

        return .success(url)
    }

    var body: some View {
        Input(
            title: "Test",
            placeholder: "Test",
            value: $requestURLInput,
            disabled: false,
            error: requestInput.error
        )
    }
}
