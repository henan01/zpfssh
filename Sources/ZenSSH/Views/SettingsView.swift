import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            AppearanceSettingsView(settings: settings)
                .tabItem { Label("外观", systemImage: "paintbrush") }

            TerminalSettingsView(settings: settings)
                .tabItem { Label("终端", systemImage: "terminal") }

            GeneralSettingsView(settings: settings)
                .tabItem { Label("通用", systemImage: "gear") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: – Appearance

struct AppearanceSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("终端主题") {
                Picker("主题", selection: $settings.appearance.themeId) {
                    ForEach(TerminalTheme.builtins) { theme in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(theme.background.nsColor))
                                .frame(width: 20, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5)
                                )
                            Text(theme.name)
                        }
                        .tag(theme.id)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("背景") {
                Picker("背景类型", selection: $settings.appearance.backgroundType) {
                    ForEach(BackgroundType.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                switch settings.appearance.backgroundType {
                case .solidColor:
                    EmptyView()

                case .image:
                    HStack(spacing: 8) {
                        if !settings.appearance.backgroundImagePath.isEmpty {
                            if let img = NSImage(contentsOfFile: settings.appearance.backgroundImagePath) {
                                Image(nsImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 60, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Text(URL(fileURLWithPath: settings.appearance.backgroundImagePath).lastPathComponent)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button("选择图片") { pickImage() }
                        if !settings.appearance.backgroundImagePath.isEmpty {
                            Button("清除") { settings.appearance.backgroundImagePath = "" }
                                .foregroundColor(.red)
                        }
                    }
                    LabeledContent("透明度") {
                        HStack(spacing: 6) {
                            Slider(value: $settings.appearance.backgroundOpacity, in: 0...0.9)
                                .frame(minWidth: 120)
                            Text("\(Int(settings.appearance.backgroundOpacity * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    LabeledContent("模糊") {
                        HStack(spacing: 6) {
                            Slider(value: $settings.appearance.backgroundBlur, in: 0...20)
                                .frame(minWidth: 120)
                            Text("\(Int(settings.appearance.backgroundBlur)) px")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Picker("填充方式", selection: $settings.appearance.imageFillMode) {
                        ForEach(ImageFillMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }

                case .gradient:
                    LabeledContent("起始颜色") {
                        ColorPicker("", selection: Binding(
                            get: { Color(settings.appearance.gradientStart.nsColor) },
                            set: { settings.appearance.gradientStart = CodableColor(NSColor($0)) }
                        ))
                        .labelsHidden()
                    }
                    LabeledContent("结束颜色") {
                        ColorPicker("", selection: Binding(
                            get: { Color(settings.appearance.gradientEnd.nsColor) },
                            set: { settings.appearance.gradientEnd = CodableColor(NSColor($0)) }
                        ))
                        .labelsHidden()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .gif, .webP]
        panel.message = "选择背景图片"
        if panel.runModal() == .OK {
            settings.appearance.backgroundImagePath = panel.url?.path ?? ""
        }
    }
}

// MARK: – Terminal

struct TerminalSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("字体") {
                Picker("字体", selection: $settings.appearance.fontName) {
                    let monoFonts = NSFontManager.shared.availableFontFamilies
                        .filter { NSFont(name: $0, size: 12)?.isFixedPitch == true }
                    ForEach(monoFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    value: $settings.appearance.fontSize,
                    in: 8...48,
                    step: 1
                ) {
                    LabeledContent("字号") {
                        Text("\(Int(settings.appearance.fontSize)) pt")
                            .monospacedDigit()
                    }
                }

                Text("AaBbCcDd 012345 !@#$%")
                    .font(.custom(settings.appearance.fontName, size: settings.appearance.fontSize))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(settings.currentTheme.background.nsColor))
                    .foregroundColor(Color(settings.currentTheme.foreground.nsColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Section("光标") {
                Toggle("光标闪烁", isOn: $settings.appearance.cursorBlink)
            }

            Section("滚动缓冲") {
                LabeledContent("缓冲行数") {
                    HStack(spacing: 4) {
                        TextField("", value: $settings.scrollbackLines, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("行")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("标签页标题") {
                TextField("标题模板", text: $settings.tabTitleTemplate)
                    .textFieldStyle(.roundedBorder)
                Text("可用变量: {hostname}  {user}  {ip}  {alias}  {index}")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

// MARK: – General

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("启动") {
                Toggle("启动时恢复上次工作区", isOn: $settings.restoreOnLaunch)
            }
            Section("广播") {
                Toggle("广播命令前显示确认对话框", isOn: $settings.confirmBroadcast)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
