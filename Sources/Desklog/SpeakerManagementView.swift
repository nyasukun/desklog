import DesklogCore
import SwiftUI

struct SpeakerManagementView: View {
    @ObservedObject var controller: DesklogController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("話者の登録")
                        .font(.title2.bold())
                    Text("発話を確認して名前を登録すると、声の特徴量から以後の発話を自動で同定します。同じ人が別の話者として検出された場合は同じ名前を指定すると、声のサンプルが1人にグルーピングされます。自分の発話には「自分」を付けてください。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("登録済み・検出済みの話者") {
                    if controller.speakerProfiles.isEmpty {
                        Text("まだ話者が検出されていません。記録を開始して発話すると、ここに表示されます。")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(controller.speakerProfiles) { profile in
                                SpeakerProfileCard(
                                    profile: profile,
                                    isUpdating: controller.updatingSpeakerID == profile.id,
                                    isBusy: controller.isUpdatingSpeaker
                                ) { name, isSelf in
                                    controller.updateSpeaker(
                                        profileID: profile.id,
                                        name: name,
                                        isSelf: isSelf
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }

                GroupBox("最近の発話から登録") {
                    if controller.recentSpeakerObservations.isEmpty {
                        Text("登録できる発話はまだありません。")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(controller.recentSpeakerObservations) { observation in
                                SpeakerObservationRow(
                                    observation: observation,
                                    profile: profile(for: observation.profileID),
                                    isUpdating: controller.updatingObservationID == observation.id,
                                    isBusy: controller.isUpdatingSpeaker
                                ) { name, isSelf in
                                    controller.labelSpeaker(
                                        observationID: observation.id,
                                        name: name,
                                        isSelf: isSelf
                                    )
                                }
                                Divider()
                            }
                        }
                    }
                }

                Label(
                    "声の特徴量と話者対応はこのMac内だけに保存されます。Ollamaへ送る要約入力には、話者名・自分タグ・文字起こしだけを含めます。",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .navigationTitle("話者")
    }

    private func profile(for id: String) -> SpeakerProfile? {
        controller.speakerProfiles.first {
            $0.id == id || $0.alternateProfileIDs.contains(id)
        }
    }
}

private struct SpeakerProfileCard: View {
    let profile: SpeakerProfile
    let isUpdating: Bool
    let isBusy: Bool
    let onSave: (String, Bool) -> Void

    @State private var name: String
    @State private var isSelf: Bool

    init(
        profile: SpeakerProfile,
        isUpdating: Bool,
        isBusy: Bool,
        onSave: @escaping (String, Bool) -> Void
    ) {
        self.profile = profile
        self.isUpdating = isUpdating
        self.isBusy = isBusy
        self.onSave = onSave
        _name = State(initialValue: profile.name ?? "")
        _isSelf = State(initialValue: profile.isSelf)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: profile.isSelf ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(profile.isConfirmed ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).fontWeight(.semibold)
                    Text(profileDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isUpdating { ProgressView().controlSize(.small) }
            }

            TextField("この話者の名前", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("自分", isOn: $isSelf)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(profile.isConfirmed ? "変更を保存" : "話者を登録") {
                    onSave(trimmedName, isSelf)
                }
                .disabled(trimmedName.isEmpty || isBusy || !hasChanges)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: profile.name) { _, value in
            name = value ?? ""
        }
        .onChange(of: profile.isSelf) { _, value in
            isSelf = value
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedName != (profile.name ?? "") || isSelf != profile.isSelf
    }

    private var profileDetail: String {
        let groupedCount = profile.alternateProfileIDs.count + 1
        let grouping = groupedCount > 1 ? "・検出グループ \(groupedCount)件" : ""
        return "\(profile.id)・声サンプル \(profile.sampleCount)件\(grouping)"
    }
}

private struct SpeakerObservationRow: View {
    let observation: SpeakerObservation
    let profile: SpeakerProfile?
    let isUpdating: Bool
    let isBusy: Bool
    let onSave: (String, Bool) -> Void

    @State private var name: String
    @State private var isSelf: Bool

    init(
        observation: SpeakerObservation,
        profile: SpeakerProfile?,
        isUpdating: Bool,
        isBusy: Bool,
        onSave: @escaping (String, Bool) -> Void
    ) {
        self.observation = observation
        self.profile = profile
        self.isUpdating = isUpdating
        self.isBusy = isBusy
        self.onSave = onSave
        _name = State(initialValue: profile?.name ?? "")
        _isSelf = State(initialValue: profile?.isSelf ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(profile?.displayName ?? observation.profileID, systemImage: "waveform.badge.mic")
                    .fontWeight(.semibold)
                if profile?.isConfirmed != true {
                    Text("未登録")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                }
                Spacer()
                Text(observation.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(observation.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if profile?.isConfirmed == true {
                Text("名前や「自分」タグは上の話者カードから変更できます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("この話者の名前", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, maxWidth: 280)
                    Toggle("自分", isOn: $isSelf)
                        .toggleStyle(.checkbox)
                    Button("この話者を登録") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), isSelf)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    if isUpdating {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 12)
        .onChange(of: profile?.name) { _, value in
            name = value ?? ""
        }
        .onChange(of: profile?.isSelf) { _, value in
            isSelf = value ?? false
        }
    }
}
