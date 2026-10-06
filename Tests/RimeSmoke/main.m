#import <Foundation/Foundation.h>
#import "HQPinyinEngine.h"

static void check(BOOL value, NSString *message) {
    if (!value) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}
static void type(HQPinyinEngine *engine, NSString *pinyin) {
    for (NSUInteger i = 0; i < pinyin.length; i++)
        check([engine processKey:[pinyin characterAtIndex:i] mask:0], @"Pinyin key must be consumed");
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        check(argc == 3, @"usage: RimeSmoke <shared-data> <user-data>");
        NSString *shared = [NSString stringWithUTF8String:argv[1]];
        NSString *user = [NSString stringWithUTF8String:argv[2]];
        HQPinyinEngine *engine = [[HQPinyinEngine alloc] initWithSharedDataPath:shared userDataPath:user];
        check(engine.available, engine.errorDescription ?: @"engine available");
        check(engine.highlightedCandidateIndex == -1, @"Empty engine has no highlighted candidate");
        for (NSArray<NSString *> *pair in @[@[@"nihao", @"你好"], @[@"kuajing", @"跨境"], @[@"zhongwen", @"中文"]]) {
            [engine clear];
            type(engine, pair[0]);
            check(engine.isComposing && engine.preedit.length > 0, @"Pinyin must remain composing before selection");
            NSUInteger index = [engine.candidates indexOfObject:pair[1]];
            check(index != NSNotFound, [NSString stringWithFormat:@"%@ should offer %@; got %@", pair[0], pair[1], engine.candidates]);
            check([engine selectCandidate:index], @"Candidate selection consumed");
            check([[engine takeCommit] isEqualToString:pair[1]], @"Selected Chinese candidate committed");
            check([engine takeCommit] == nil, @"Commit is consumed exactly once");
            check(!engine.isComposing, @"Composition cleared after commit");
            printf("PASS: %s → %s\n", pair[0].UTF8String, pair[1].UTF8String);
        }
        // Use a single syllable so selecting a candidate always ends this composition.
        for (NSNumber *useSpace in @[@NO, @YES]) {
            [engine clear];
            type(engine, @"hao");
            check(engine.candidates.count > 1 && engine.highlightedCandidateIndex == 0, @"First candidate initially highlighted");
            check([engine processKey:0xff54 mask:0], @"Down arrow is consumed");
            check(engine.highlightedCandidateIndex == 1, @"Down arrow highlights the second visible candidate");
            check([engine processKey:0xff52 mask:0] && engine.highlightedCandidateIndex == 0, @"Up arrow restores the first candidate");
            check([engine processKey:0xff54 mask:0] && engine.highlightedCandidateIndex == 1, @"Down arrow restores the second candidate");
            NSString *highlightedText = engine.candidates[(NSUInteger)engine.highlightedCandidateIndex];
            if (useSpace.boolValue) {
                check([engine processKey:32 mask:0], @"Space confirms the highlighted candidate");
            } else {
                check([engine selectCandidate:(NSUInteger)engine.highlightedCandidateIndex], @"Explicit selection confirms the highlighted candidate");
            }
            check([[engine takeCommit] isEqualToString:highlightedText], @"Committed text must match the displayed highlighted candidate");
            check(engine.highlightedCandidateIndex == -1, @"Committing clears highlighted candidate");
        }
        printf("PASS: arrow-key highlight agrees with explicit selection and space commit\n");
        type(engine, @"nihao");
        [engine processKey:0xff08 mask:0];
        check(engine.isComposing && ![engine.preedit containsString:@"hao"], @"Backspace edits preedit");
        [engine clear];
        check(!engine.isComposing && engine.candidates.count == 0, @"Clear cancels composition");
        check(engine.highlightedCandidateIndex == -1, @"Clear removes candidate highlight");
        check(![engine selectCandidate:99], @"Out-of-range candidate safely rejected");
        HQPinyinEngine *second = [[HQPinyinEngine alloc] initWithSharedDataPath:shared userDataPath:user];
        check(second.available, @"Additional independent session available");
        type(engine, @"nihao");
        type(second, @"kuajing");
        check([engine.candidates containsObject:@"你好"] && [second.candidates containsObject:@"跨境"], @"Session composition is isolated");
        [engine clear];
        [second clear];
        printf("PASS: deletion, cancellation, single-use commits, bounds, independent sessions\n");
    }
    return 0;
}
