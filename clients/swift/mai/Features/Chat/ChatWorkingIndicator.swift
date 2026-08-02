import SwiftUI

/// The "agent is working" row: a sparkle and a whimsical verb. The verb
/// advances only when the agent starts something new (`activityKey` changes,
/// e.g. a fresh tool call or message row); a long-lived phrase is fine.
struct ChatWorkingIndicator: View {
    var activityKey: String?

    @State private var phrase = ChatWorkingPhrases.next(after: nil)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption)
                .symbolEffect(.pulse, options: .repeating)

            Text(phrase)
                .id(phrase)
                .transition(.blurReplace)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .animation(.smooth(duration: 0.6), value: phrase)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent working")
        .onChange(of: activityKey) { _, _ in
            phrase = ChatWorkingPhrases.next(after: phrase)
        }
    }
}

enum ChatWorkingPhrases {
    static func next(after current: String?) -> String {
        var phrase = all.randomElement() ?? "Working…"
        while phrase == current, all.count > 1 {
            phrase = all.randomElement() ?? phrase
        }
        return phrase
    }

    static let all: [String] = [
        // Short
        "Combobulating…",
        "Channelling…",
        "Vibing…",
        "Concocting…",
        "Spelunking…",
        "Transmuting…",
        "Pontificating…",
        "Whirring…",
        "Cogitating…",
        "Noodling…",
        "Percolating…",
        "Ruminating…",
        "Simmering…",
        "Marinating…",
        "Brewing…",
        "Steeping…",
        "Contemplating…",
        "Musing…",
        "Pondering…",
        "Mulling…",
        "Daydreaming…",
        "Tinkering…",
        "Finagling…",
        "Wrangling…",
        "Galumphing…",
        "Meandering…",
        "Moseying…",
        "Puttering…",
        "Discombobulating…",
        "Recombobulating…",
        "Confabulating…",
        "Effervescing…",
        "Fizzing…",
        "Bubbling…",
        "Mesmerizing…",
        "Sparkling…",
        "Scintillating…",
        "Synthesizing…",
        "Sleuthing…",
        "Rummaging…",
        "Foraging…",
        "Grooving…",
        "Improvising…",
        "Frolicking…",
        "Wibbling…",
        "Burbling…",
        "Whooshing…",
        "Doodling…",
        "Scribbling…",
        "Shimmering…",
        "Humming…",
        "Strumming…",
        "Thrumming…",
        "Fumbling…",
        "Untangling…",
        "Unravelling…",
        "Deciphering…",
        "Conjuring…",
        "Incanting…",
        "Enchanting…",
        // Long
        "Consulting the void…",
        "Asking the electrons…",
        "Bribing the compiler…",
        "Negotiating with entropy…",
        "Whispering to the bits…",
        "Tickling the stack…",
        "Appeasing the garbage collector…",
        "Herding pointers…",
        "Untangling spaghetti…",
        "Consulting ancient scrolls…",
        "Reading tea leaves…",
        "Warming up the hamsters…",
        "Caffeinating…",
        "Having a little think…",
        "Squinting at the problem…",
        "Consulting the oracle…",
        "Reticulating splines…",
        "Reversing the polarity…",
        "Calibrating the flux capacitor…",
        "Politely asking the CPU…",
        "Consulting the rubber duck…",
        "Interrogating the stack trace…",
        "Checking under the hood…",
        "Greasing the gears…",
        "Feeding the machine…",
        "Taming wild pointers…",
        "Waltzing through the codebase…",
        "Manifesting solutions…",
        "Believing really hard…",
        "Cherry-picking the commits…",
    ]
}

#if DEBUG
    #Preview("Working Indicator") {
        ChatWorkingIndicator()
            .padding()
    }
#endif
