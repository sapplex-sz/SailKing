#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// A session-local Chinese Pinyin engine. Call UI-facing methods on the main thread.
/// All sessions in one process must use the same shared/user data directories.
@interface HQPinyinEngine : NSObject
- (instancetype)initWithSharedDataPath:(NSString *)sharedDataPath
                         userDataPath:(NSString *)userDataPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) BOOL available;
@property(nonatomic, readonly) BOOL isComposing;
@property(nonatomic, copy, readonly) NSArray<NSString *> *candidates;
/// Zero-based index on the visible page, or -1 when there is no candidate.
@property(nonatomic, readonly) NSInteger highlightedCandidateIndex;
@property(nonatomic, copy, readonly) NSString *preedit;
@property(nonatomic, copy, readonly, nullable) NSString *errorDescription;
/// Rime/X11 key symbols, not macOS hardware key codes. ASCII letters map directly.
/// Return/Escape/Backspace = 0xff0d/0xff1b/0xff08. Shift/Control/Alt masks = 1/4/8.
- (BOOL)processKey:(int32_t)code mask:(int32_t)mask;
/// Zero-based index on the visible candidate page. Partial phrases can remain composing.
- (BOOL)selectCandidate:(NSUInteger)index;
/// The committed Chinese text, consumed exactly once; nil when nothing is committed.
- (nullable NSString *)takeCommit;
/// Cancels the active preedit and clears any unconsumed commit.
- (void)clear;
@end

NS_ASSUME_NONNULL_END
