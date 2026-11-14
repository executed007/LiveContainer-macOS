import SwiftUI

// Small building blocks shared by the views.

struct AppIconView: View {
    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(width: size, height: size)
    }
}

/// A titled group of rows on a rounded background, like a grouped Form section, but usable
/// inside a scroll view next to other content.
struct SettingsSection<Content: View>: View {
    let title: String
    var systemImage: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage ?? "")
                .labelStyle(TitleOnlyIfEmptyLabelStyle(hasIcon: systemImage != nil))
                .font(.headline)
            VStack(spacing: 0) {
                Group { content }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Icon and title, or just the icon when space is short.
struct CompactLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { HStack(spacing: 5) { configuration.icon; configuration.title } }
    }
}

struct TitleOnlyIfEmptyLabelStyle: LabelStyle {
    let hasIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        if hasIcon {
            HStack(spacing: 6) { configuration.icon.foregroundStyle(.secondary); configuration.title }
        } else {
            configuration.title
        }
    }
}

/// A setting with its switch on the trailing edge, as in System Settings.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }
            .toggleStyle(.switch).controlSize(.small)
    }
}

/// A divider between rows inside a SettingsSection.
struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 14).padding(.vertical, -10) }
}

struct StatusBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct RunningDot: View {
    var body: some View {
        Circle().fill(.green).frame(width: 7, height: 7)
            .overlay(Circle().stroke(.green.opacity(0.35), lineWidth: 3))
            .accessibilityLabel("Running")
    }
}

/// Install progress and short confirmations, floating at the bottom of the window.
struct ActivityOverlay: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 8) {
            if let activity = model.activity {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(activity.title).font(.callout.weight(.semibold))
                        Text(activity.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 320)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout).symbolRenderingMode(.multicolor)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(duration: 0.3), value: model.activity)
        .animation(.spring(duration: 0.3), value: model.notice)
    }
}

/// Shown while files are dragged over the window.
struct DropOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 7]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.app.fill").font(.system(size: 46)).foregroundStyle(Color.accentColor)
                Text("Drop to install").font(.title3.weight(.semibold))
                Text(".ipa files install as apps; .dylib and .framework files are added as tweaks")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .allowsHitTesting(false)
    }
}

func formattedSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
