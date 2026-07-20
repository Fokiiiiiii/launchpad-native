import Testing
@testable import Triggers

private func packData1(keyCode: Int, keyDown: Bool, isRepeat: Bool) -> Int {
    let keyState = keyDown ? 1 : 0
    let keyFlags = (keyState << 8) | (isRepeat ? 1 : 0)
    return (keyCode << 16) | keyFlags
}

@Test func classifiesLaunchPanelKeyDown() {
    let data1 = packData1(keyCode: 13, keyDown: true, isRepeat: false)
    let event = F4EventClassifier.classify(subtype: 8, data1: data1)
    #expect(event?.keyCode == 13)
    #expect(event?.isKeyDown == true)
    #expect(event?.isRepeat == false)
    #expect(F4EventClassifier.isLaunchPanelActivation(event!))
}

@Test func ignoresNonAuxControlButtonsSubtype() {
    let data1 = packData1(keyCode: 13, keyDown: true, isRepeat: false)
    #expect(F4EventClassifier.classify(subtype: 99, data1: data1) == nil)
}

@Test func keyUpIsNotAnActivation() {
    let data1 = packData1(keyCode: 13, keyDown: false, isRepeat: false)
    let event = F4EventClassifier.classify(subtype: 8, data1: data1)!
    #expect(F4EventClassifier.isLaunchPanelActivation(event) == false)
}

@Test func autoRepeatIsNotAnActivation() {
    let data1 = packData1(keyCode: 13, keyDown: true, isRepeat: true)
    let event = F4EventClassifier.classify(subtype: 8, data1: data1)!
    #expect(F4EventClassifier.isLaunchPanelActivation(event) == false)
}

@Test func otherKeyCodesAreNotLaunchPanel() {
    let data1 = packData1(keyCode: 7, keyDown: true, isRepeat: false) // NX_KEYTYPE_SOUND_UP-ish
    let event = F4EventClassifier.classify(subtype: 8, data1: data1)!
    #expect(F4EventClassifier.isLaunchPanelActivation(event) == false)
}
