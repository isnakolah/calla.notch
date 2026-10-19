//
//  InlineHUDs.swift
//  callaNotch
//
//  Created by Richard Kunkli on 14/09/2024.
//

import SwiftUI
import Defaults

struct InlineHUD: View {
    @EnvironmentObject var vm: CallaViewModel
    @Binding var type: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    /// Icon on the left, its level on the right: a 64pt meter, or for the mic a
    /// flat row of bars. No words — the label and percentage stay opt-in.
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if Defaults[.showInlineHUDLabel] {
                    Text(Type2Name(type))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .allowsTightening(true)
                        .contentTransition(.numericText())
                }
                Group {
                    switch (type) {
                        case .volume:
                            if icon.isEmpty {
                                Image(systemName: SpeakerSymbol(value))
                                    .contentTransition(.interpolate)
                                    .symbolVariant(value > 0 ? .none : .slash)
                            } else {
                                Image(systemName: icon)
                                    .contentTransition(.interpolate)
                                    .opacity(value.isZero ? 0.6 : 1)
                            }
                        case .brightness:
                            Image(systemName: BrightnessSymbol(value))
                                .contentTransition(.interpolate)
                        case .backlight:
                            Image(systemName: value > 0.5 ? "light.max" : "light.min")
                                .contentTransition(.interpolate)
                        case .mic:
                            Image(systemName: "mic")
                                .symbolVariant(value > 0 ? .none : .slash)
                                .contentTransition(.interpolate)
                        default:
                            EmptyView()
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 15, alignment: .trailing)

            }
            // The slab between the wings is narrower than the housing, so the
            // glyph keeps a few points clear of the camera's edge.
            .padding(.trailing, 8)
            .frame(width: NotchWing.hud + gestureProgress / 2, alignment: .trailing)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            HStack(spacing: 6) {
                if type == .mic {
                    micLevel
                } else {
                    DraggableProgressBar(value: $value, onChange: { v in
                        if type == .volume {
                            VolumeManager.shared.setAbsolute(Float32(v))
                        } else if type == .brightness {
                            BrightnessManager.shared.setAbsolute(value: Float32(v))
                        }
                    }, tint: tint)
                    .frame(width: 64)
                    if Defaults[.showClosedNotchHUDPercentage] {
                        Text("\(Int(value * 100))%")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(NotchInk.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 8)
            .frame(width: NotchWing.hud + gestureProgress / 2, alignment: .leading)
        }
        .frame(height: vm.closedNotchSize.height + (hoverAnimation ? 8 : 0), alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The level a muted mic has: five bars, all flat, in orange.
    private var micLevel: some View {
        let muted = value.isZero
        return HStack(spacing: 1.3) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(muted ? NotchAccent.attention : NotchInk.primary)
                    .frame(width: 2.5, height: muted ? 2.5 : [4, 10, 14, 8, 4][index])
            }
        }
        .frame(width: 18, height: 14)
    }

    private var tint: Color {
        switch type {
        case .brightness, .backlight: return NotchAccent.focus
        case .mic: return value.isZero ? NotchAccent.attention : NotchInk.primary
        default: return NotchInk.primary
        }
    }

    private var accessibilityText: String {
        if type == .mic { return value.isZero ? "Microphone muted" : "Microphone on" }
        return "\(Type2Name(type)) \(Int(value * 100)) percent"
    }

    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
    
    func BrightnessSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0...0.6:
                return "sun.min"
            case 0.6...1:
                return "sun.max"
            default:
                return "sun.min"
        }
    }
    
    func Type2Name(_ type: SneakContentType) -> String {
        switch(type) {
            case .volume:
                return "Volume"
            case .brightness:
                return "Brightness"
            case .backlight:
                return "Backlight"
            case .mic:
                return "Mic"
            default:
                return ""
        }
    }
}

#Preview {
    InlineHUD(type: .constant(.brightness), value: .constant(0.4), icon: .constant(""), hoverAnimation: .constant(false), gestureProgress: .constant(0))
        .padding(.horizontal, 8)
        .background(Color.black)
        .padding()
        .environmentObject(CallaViewModel())
}
