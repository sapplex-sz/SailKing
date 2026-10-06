#import "HQPinyinEngine.h"
#include <rime_api.h>

static RimeApi *HQAPI;
static NSString *HQSharedPath;
static NSString *HQUserPath;
static BOOL HQInitialized;

@interface HQPinyinEngine () {
    RimeSessionId _session;
    NSMutableString *_pendingCommit;
}
@property(nonatomic, readwrite) BOOL available;
@property(nonatomic, readwrite) BOOL isComposing;
@property(nonatomic, copy, readwrite) NSArray<NSString *> *candidates;
@property(nonatomic, readwrite) NSInteger highlightedCandidateIndex;
@property(nonatomic, copy, readwrite) NSString *preedit;
@property(nonatomic, copy, readwrite, nullable) NSString *errorDescription;
@end

@implementation HQPinyinEngine

- (instancetype)initWithSharedDataPath:(NSString *)sharedDataPath userDataPath:(NSString *)userDataPath {
    self = [super init];
    if (!self) return nil;
    _candidates = @[];
    _highlightedCandidateIndex = -1;
    _preedit = @"";
    _pendingCommit = [NSMutableString new];
    @synchronized(HQPinyinEngine.class) {
        NSFileManager *files = NSFileManager.defaultManager;
        NSString *schema = [sharedDataPath stringByAppendingPathComponent:@"luna_pinyin_simp.schema.yaml"];
        if (![files fileExistsAtPath:schema]) {
            _errorDescription = @"缺少拼音词库，请重新构建或安装海王输入法。";
            return self;
        }
        NSError *directoryError;
        if (![files createDirectoryAtPath:userDataPath withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
            _errorDescription = directoryError.localizedDescription;
            return self;
        }
        if (HQInitialized && (![HQSharedPath isEqualToString:sharedDataPath] || ![HQUserPath isEqualToString:userDataPath])) {
            _errorDescription = @"同一进程的拼音会话必须使用相同的词库目录。";
            return self;
        }
        if (!HQInitialized) {
            HQSharedPath = [sharedDataPath copy];
            HQUserPath = [userDataPath copy];
            HQAPI = rime_get_api();
            RIME_STRUCT(RimeTraits, traits);
            traits.shared_data_dir = HQSharedPath.fileSystemRepresentation;
            traits.user_data_dir = HQUserPath.fileSystemRepresentation;
            traits.distribution_name = "HaiWang Input";
            traits.distribution_code_name = "haiwang";
            traits.distribution_version = "0.1.0";
            traits.app_name = "rime.haiwang";
            // No raw keystrokes or text are written to logs by this bridge.
            traits.min_log_level = 2;
            traits.log_dir = "";
            HQAPI->setup(&traits);
            HQAPI->initialize(&traits);
            // This prepares an isolated user dictionary; it never touches ~/Library/Rime.
            HQAPI->start_maintenance(False);
            HQAPI->join_maintenance_thread();
            HQInitialized = YES;
        }
        _session = HQAPI->create_session();
        _available = _session && HQAPI->select_schema(_session, "luna_pinyin_simp");
        if (!_available) {
            _errorDescription = @"拼音词库初始化失败，请检查 RimeData 和用户数据目录。";
        } else {
            HQAPI->set_option(_session, "ascii_mode", False);
            HQAPI->set_option(_session, "zh_hans", True);
            HQAPI->set_option(_session, "full_shape", False);
            [self refreshLocked];
        }
    }
    return self;
}

- (void)dealloc {
    @synchronized(HQPinyinEngine.class) {
        if (_session && HQAPI) HQAPI->destroy_session(_session);
    }
}

- (BOOL)processKey:(int32_t)code mask:(int32_t)mask {
    @synchronized(HQPinyinEngine.class) {
        if (!_available) return NO;
        BOOL handled = HQAPI->process_key(_session, code, mask);
        [self refreshLocked];
        return handled;
    }
}

- (BOOL)selectCandidate:(NSUInteger)index {
    @synchronized(HQPinyinEngine.class) {
        if (!_available || index >= _candidates.count) return NO;
        BOOL handled = HQAPI->select_candidate_on_current_page(_session, index);
        [self refreshLocked];
        return handled;
    }
}

- (NSString *)takeCommit {
    @synchronized(HQPinyinEngine.class) {
        if (!_pendingCommit.length) return nil;
        NSString *result = [_pendingCommit copy];
        [_pendingCommit setString:@""];
        return result;
    }
}

- (void)clear {
    @synchronized(HQPinyinEngine.class) {
        if (_available) HQAPI->clear_composition(_session);
        [_pendingCommit setString:@""];
        _preedit = @"";
        _candidates = @[];
        _highlightedCandidateIndex = -1;
        _isComposing = NO;
    }
}

- (void)refreshLocked {
    RIME_STRUCT(RimeCommit, commit);
    if (HQAPI->get_commit(_session, &commit)) {
        if (commit.text) [_pendingCommit appendString:[NSString stringWithUTF8String:commit.text] ?: @""];
        HQAPI->free_commit(&commit);
    }
    RIME_STRUCT(RimeContext, context);
    if (HQAPI->get_context(_session, &context)) {
        _preedit = context.composition.preedit ? ([NSString stringWithUTF8String:context.composition.preedit] ?: @"") : @"";
        _isComposing = context.composition.length > 0;
        NSMutableArray<NSString *> *items = [NSMutableArray new];
        for (int i = 0; i < context.menu.num_candidates; i++) {
            const char *text = context.menu.candidates[i].text;
            [items addObject:text ? ([NSString stringWithUTF8String:text] ?: @"") : @""];
        }
        _candidates = [items copy];
        NSInteger highlighted = context.menu.highlighted_candidate_index;
        _highlightedCandidateIndex = highlighted >= 0 && highlighted < (NSInteger)items.count ? highlighted : -1;
        HQAPI->free_context(&context);
    } else {
        _preedit = @"";
        _candidates = @[];
        _highlightedCandidateIndex = -1;
        _isComposing = NO;
    }
}
@end
