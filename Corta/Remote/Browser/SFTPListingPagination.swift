// Copyright 2026 Noah Qin
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct SFTPListingPagination: View {
    let model: SFTPBrowserModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.showListingPage(model.listingPage - 1)
            } label: {
                Label(L10n.text("sftp.page.previous"), systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
            }
            .help(L10n.text("sftp.page.previous"))
            .disabled(model.listingPage == 0)

            Menu {
                ForEach(0..<model.listingPageCount, id: \.self) { page in
                    Button {
                        model.showListingPage(page)
                    } label: {
                        Text(page + 1, format: .number)
                    }
                    .disabled(page == model.listingPage)
                }
            } label: {
                Text(L10n.format("sftp.page.count", model.listingPage + 1, model.listingPageCount))
                    .monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                model.showListingPage(model.listingPage + 1)
            } label: {
                Label(L10n.text("sftp.page.next"), systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
            }
            .help(L10n.text("sftp.page.next"))
            .disabled(model.listingPage == model.listingPageCount - 1)
        }
        .buttonStyle(.borderless)
        .disabled(model.isLoading)
    }
}
