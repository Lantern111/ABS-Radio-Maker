import SwiftUI

/// Trimming, loudness, and the other edits to the sound, plus fixing where songs were detected.
struct AudioPanel: View {
    @Bindable var studio: Studio

    var body: some View {
        // Read so the song button's wording follows the playback position.
        let _ = (studio.player.seekRevision, studio.player.isPlaying)
        Form {
            Section {
                LabeledContent("시작", value: TimeText.format(studio.audioOptions.trimStart))
                LabeledContent("끝", value: TimeText.format(studio.audioOptions.trimEnd ?? studio.recordingDuration))
                HStack {
                    Button("재생 위치에서 시작", action: studio.startHere)
                    Button("재생 위치에서 끝", action: studio.endHere)
                }
                if studio.audioOptions.trimStart > 0 || studio.audioOptions.trimEnd != nil {
                    Button("자르기 취소", action: studio.clearTrim)
                }
            } header: {
                Text("자르기")
            } footer: {
                Text("아래 타임라인에서 원하는 곳으로 옮긴 뒤 누르세요.")
            }
            .disabled(!studio.hasRecording)

            Section {
                Toggle("소리 크기 맞추기", isOn: $studio.audioOptions.normalizesLoudness)
                if studio.audioOptions.normalizesLoudness {
                    Picker("목표", selection: $studio.audioOptions.targetLoudness) {
                        ForEach(AudioEditOptions.loudnessChoices, id: \.value) { choice in
                            Text(choice.label).tag(choice.value)
                        }
                    }
                }
                if let before = studio.processed?.loudnessBefore {
                    LabeledContent("원래 소리 크기", value: String(format: "%.1f LUFS", before))
                }
                Toggle("웅웅거리는 저음 줄이기", isOn: $studio.audioOptions.removesRumble)
                Toggle("긴 침묵 줄이기", isOn: $studio.audioOptions.shortensSilences)
            } header: {
                Text("소리 다듬기")
            } footer: {
                Text("소리 크기를 맞추면 큰 소리가 찢어지지 않게 자동으로 눌러 줘요. 긴 침묵 줄이기는 1.5초보다 긴 멈춤을 0.5초로 줄여요.")
            }

            Section("페이드") {
                SettingSlider(title: "시작할 때 커지기", value: $studio.audioOptions.fadeIn, range: 0...5, format: seconds)
                SettingSlider(title: "끝날 때 작아지기", value: $studio.audioOptions.fadeOut, range: 0...10, format: seconds)
            }

            Section {
                Button(studio.isSongAtPlayhead ? "이 구간은 말하기예요" : "이 구간은 노래예요", action: studio.flipSegmentAtPlayhead)
                if studio.segmentsWereEdited {
                    Button("자동으로 찾은 대로 되돌리기", action: studio.restoreDetectedSegments)
                }
            } header: {
                Text("노래 구간")
            } footer: {
                Text("노래가 나오면 캐릭터가 눈을 감고 음악을 들어요. 자동으로 찾은 구간이 틀렸다면 타임라인에서 그 구간으로 옮긴 뒤 위 버튼을 누르세요.")
            }
            .disabled(!studio.hasRecording)
        }
        .formStyle(.grouped)
    }

    private func seconds(_ value: Double) -> String {
        value == 0 ? "없음" : String(format: "%.1f초", value)
    }
}
