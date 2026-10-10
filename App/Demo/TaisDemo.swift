import Foundation
import PixlModel

/// Stage 14's UI-test states (no network, no Core ML): the job and model states each `tais.*` screen shows.
@MainActor
enum TaisDemo {
    static func apply(launch: LaunchConfiguration, to tais: TaisServices) {
        guard let screen = launch.screen else { return }
        let songs = DemoLibrary.songs
        guard !songs.isEmpty else { return }
        let song = songs[min(max(launch.songIndex, 0), songs.count - 1)]
        let sheetSong = songs.first ?? song
        let studio = tais.studio, models = tais.models
        func running(_ percent: Int, _ detail: String) -> TaisStudio.JobState {
            TaisStudio.JobState(phase: .running, percent: percent, detail: detail, indeterminate: false)
        }
        switch screen {
        case .taisStudio:
            studio.setDemoState(TaisStudio.JobState(phase: .succeeded(updated: true), percent: 100, detail: "Instrumental ready.",
                                                    indeterminate: false), kind: .instrumental, songId: song.id)
            studio.setDemoState(running(63, "\(song.title) — pass 5 of 8…"), kind: .lyrics, songId: song.id)
            studio.setDemoState(TaisStudio.JobState(
                phase: .failed("BS-RoFormer render failed — check the backend URL/route in Experimental Settings and try again."),
                percent: 0, detail: nil, indeterminate: false), kind: .roformer, songId: song.id)
            models.setDemoState(.installed(bytes: 188_400_000), for: .wav2vec2)
            models.setDemoState(.installed(bytes: 33_200_000), for: .mdxnet)
        case .taisModels:
            models.setDemoState(.downloading(fraction: 0.42), for: .wav2vec2)
            models.setDemoState(.installed(bytes: 33_200_000), for: .mdxnet)
            studio.setDemoState(running(0, "Downloading the lyric sync model — 42%"), kind: .lyrics, songId: song.id)
        case .taisSongSheet:
            studio.setDemoState(running(37, "Rendering the instrumental — 37% through the track…"), kind: .instrumental,
                                songId: sheetSong.id)
            studio.setDemoState(TaisStudio.JobState(phase: .succeeded(updated: true), percent: 100,
                                                    detail: "Word-synced lyrics from LRCLIB", indeterminate: false),
                                kind: .lyrics, songId: sheetSong.id)
        case .settingsAILocalModel:
            models.setDemoState(.downloading(fraction: 0.42), for: .llm)
        case .settingsAILocalModelReady:
            models.setDemoState(.installed(bytes: ModelCatalog.llm.bytes + 2_400_000), for: .llm)
        case .settingsAILocalModelFailed:
            models.setDemoState(.failed(JobFailureText.httpStatus(404)), for: .llm)
        case .taisInstrumental:
            tais.instrumental.setDemo(available: true, active: false)
        case .taisInstrumentalActive:
            tais.instrumental.setDemo(available: true, active: true)
        case .taisInstrumentalRendering:
            studio.setDemoState(running(48, "Rendering the instrumental — 48% through the track…"), kind: .instrumental,
                                songId: song.id)
        default:
            break
        }
    }
}
