import Testing
@testable import Voice

struct DictationInputTests {
    @Test func wrapsRequestAndFollowupAsSeparateDictations() {
        // Synthetic requests exercise imperative and question-shaped dictation.
        let request = "Please move the garden chairs into the shed."
        let followup = "Can you check whether the cushions are dry?"

        #expect(Prompts.dictationInput(request) == "<dictation>Please move the garden chairs into the shed.</dictation>")
        #expect(Prompts.dictationInput(followup) == "<dictation>Can you check whether the cushions are dry?</dictation>")
    }

    @Test func preservesWhitespacePunctuationAndLiteralMarkup() {
        let raw = "  Keep ‘this’ & <that>.\n\nNew paragraph.  "

        #expect(Prompts.dictationInput(raw) == "<dictation>  Keep ‘this’ & <that>.\n\nNew paragraph.  </dictation>")
    }
}
