# 말하기 감지 모델 (TalkDetector)

앱이 "아나운서가 지금 말하고 있는지"를 판단하는 데 쓰는 모델이에요. 노래 구간이 아니어도 아무도 말하지 않으면 캐릭터 입을 다물게 해요. macOS 기본 소리 분류기는 BGM 위에서 말하는지 잘 구분하지 못해서, 방송 녹음으로 직접 학습시켰어요.

## 만드는 방식

손으로 라벨을 붙이지 않아요. 녹음에서 확실한 것만 써요.

- 마이크는 모노이고 BGM은 스테레오예요. 그래서 **왼쪽과 오른쪽이 완전히 같은 구간 = 마이크만 켜진 구간**이에요. 그 안에서는 말과 쉼을 소리 크기로 정확히 나눌 수 있어요.
- 노래는 기본 분류기가 "음악, 말소리 없음"이라고 확신하는 곳에서 가져와요.
- 깨끗한 마이크 소리에 노래를 -25 ~ -3 dB로 일부러 섞어서 **BGM 위에서 말함**과 **BGM 속 쉼**을 함께 가르쳐요. 노래만 나오는 소리도 "말 안 함"에 넣어요(노래 부르는 건 말하는 게 아니에요).
- 1초짜리 16 kHz 모노 클립이고, 가운데 0.5초에 무엇이 있는지로 `talk` / `quiet`를 정해요.
- Apple 소리 특징 추출기 위에 작은 신경망 층만 학습해요(Create ML 전이 학습). 모델은 260 KB예요.

## 다시 학습시키기

녹음(WAV, 44.1 kHz 16비트 스테레오)이 있는 폴더를 넣어요. 3개 방송은 학습에서 빼고 시험에만 써요(`MakeDataset.swift`와 `Evaluate.swift`의 `heldOut`).

```sh
Training/build.sh MakeDataset
.build/tools/MakeDataset/MakeDataset "/Volumes/DOHYEON USB/방송" .build/training-data

mkdir -p .build/tools/Train && cp Training/Train.swift .build/tools/Train/main.swift
xcrun swiftc -O -o .build/tools/Train/Train .build/tools/Train/main.swift
.build/tools/Train/Train .build/training-data .build/training-model/TalkDetector.mlmodel

Training/build.sh Evaluate
.build/tools/Evaluate/Evaluate .build/training-model/TalkDetector.mlmodel .build/training-data "/Volumes/DOHYEON USB/방송"
```

결과가 좋으면 `.build/training-model/TalkDetector.mlmodel`을 `ABS Radio Maker/TalkDetectorModel.mlmodel`로 복사해요. MP3는 학습 데이터로 쓰지 마세요. 손실 압축이라 왼쪽과 오른쪽이 비트 단위로 같지 않아서 마이크만 켜진 구간을 찾을 수 없어요.

## 결과 (2026년 11월, 방송 14개 중 11개로 학습)

학습에 쓰지 않은 방송 3개로 확인했어요.

| | 정확도 |
|---|---|
| 시험 클립: 말함 | 99.7% |
| 시험 클립: 말 안 함 | 99.1% |

마이크만 켜진 1분 구간 9곳에 같은 방송의 노래를 섞은 뒤, 깨끗한 마이크로 정한 입모양을 정답으로 비교했어요. "쉼 동안 입이 움직임"은 깨끗한 마이크에서 입이 0.5초 이상 닫혀 있는 동안 입이 열린 비율이에요.

| BGM 크기 | 쉼 동안 입이 움직임 (기본 분류기 → 학습 모델) | 말할 때 입이 안 열림 |
|---|---|---|
| -18 dB | 1.0% → 0.6% | 12.5% → 13.0% |
| -12 dB | 4.5% → 1.4% | 17.1% → 17.8% |
| -6 dB | 12.8% → 2.1% | 22.4% → 23.9% |

앱은 0.25초마다 판단하고, 이웃 판단과 평균해 0.65 이상이면 말하는 중으로 봐요(`TalkTimeline`).
