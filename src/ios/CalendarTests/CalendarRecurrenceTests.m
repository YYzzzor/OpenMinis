#import <XCTest/XCTest.h>
#import <EventKit/EventKit.h>
#import <CoreLocation/CoreLocation.h>
#import "CalendarOffload.h"
#import "NativeOffloadUtils.h"

// 通过产品命令真实保存到独立模拟器日历，再用另一个 store 读取实际发生日期。
// 每个测试只删除自己创建的唯一日历，不读取或修改用户日历事件。
@interface CalendarRecurrenceTests : XCTestCase
@property (nonatomic, strong) EKEventStore *store;
@property (nonatomic, strong) EKCalendar *testCalendar;
@property (nonatomic, copy) NSString *calendarID;
@property (nonatomic, copy) NSString *reminderCalendarID;
@end

@implementation CalendarRecurrenceTests

- (void)setUp {
    [super setUp];
    self.continueAfterFailure = NO;
    static EKEventStore *verificationStore;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ verificationStore = [[EKEventStore alloc] init]; });
    self.store = verificationStore;
    XCTestExpectation *access = [self expectationWithDescription:@"calendar access"];
    [self.store requestFullAccessToEventsWithCompletion:^(BOOL granted, NSError *error) {
        XCTAssertTrue(granted, @"Grant simulator calendar permission to com.openminis.app: %@", error);
        [access fulfill];
    }];
    [self waitForExpectations:@[access] timeout:15];
    [self.store reset];
    // 获取提醒事项权限后 sources 还会包含提醒事项来源；Local 类型本身不能证明支持事件。
    EKSource *source = self.store.defaultCalendarForNewEvents.source;
    if (source.sourceType != EKSourceTypeLocal) source = nil;
    if (!source) {
        for (EKCalendar *calendar in [self.store calendarsForEntityType:EKEntityTypeEvent]) {
            if (calendar.source.sourceType == EKSourceTypeLocal) {
                source = calendar.source;
                break;
            }
        }
    }
    XCTAssertNotNil(source, @"Tests require a simulator local source that supports event calendars.");
    self.testCalendar = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:self.store];
    self.testCalendar.title = [@"MinisX-Recurrence-Test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    self.testCalendar.source = source;
    NSError *error = nil;
    XCTAssertTrue([self.store saveCalendar:self.testCalendar commit:YES error:&error], @"%@", error);
    self.calendarID = self.testCalendar.calendarIdentifier;
    // 独立 store 的保存通知可能晚于固定延时；以产品读路径实际可见为准，不重试创建操作。
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 5.0;
    BOOL visible = NO;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        int status;
        NSDictionary *listed = [self invokeCommand:@"calendars" options:@[] exit:&status
            timeout:MAX(0.001, deadline - NSProcessInfo.processInfo.systemUptime)];
        XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", listed);
        NSArray *calendars = listed[@"data"][@"calendars"];
        XCTAssertTrue([calendars isKindOfClass:NSArray.class], @"Invalid calendars response: %@", listed);
        for (NSDictionary *calendar in calendars) {
            if ([calendar[@"id"] isEqualToString:self.calendarID] &&
                [calendar[@"title"] isEqualToString:self.testCalendar.title]) {
                visible = YES;
                break;
            }
        }
        if (visible) break;
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) break;
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.1, remaining)]];
    }
    XCTAssertTrue(visible, @"Test calendar %@ (%@) was not visible through apple-calendar calendars within 5 seconds.",
        self.testCalendar.title, self.calendarID);
}

- (void)tearDown {
    if (self.calendarID) {
        NSError *error = nil;
        XCTAssertTrue([self.store removeCalendar:[self.store calendarWithIdentifier:self.calendarID] commit:YES error:&error], @"%@", error);
    }
    if (self.reminderCalendarID) {
        NSError *error = nil;
        XCTAssertTrue([self.store removeCalendar:[self.store calendarWithIdentifier:self.reminderCalendarID] commit:YES error:&error], @"%@", error);
    }
    self.reminderCalendarID = nil;
    self.testCalendar = nil;
    self.store = nil;
    [super tearDown];
}

- (NSDictionary *)invoke:(NSArray<NSString *> *)options exit:(int *)exitCode {
    return [self invokeCommand:@"create" options:options exit:exitCode];
}

- (NSDictionary *)invokeCommand:(NSString *)command options:(NSArray<NSString *> *)options exit:(int *)exitCode {
    return [self invokeCommand:command options:options exit:exitCode timeout:40];
}

- (NSDictionary *)invokeCommand:(NSString *)command options:(NSArray<NSString *> *)options exit:(int *)exitCode timeout:(NSTimeInterval)timeout {
    return [self invokeCommand:command options:options exit:exitCode timeout:timeout sharedReminderEntry:NO];
}

- (NSDictionary *)invokeReminderCommand:(NSString *)command options:(NSArray<NSString *> *)options exit:(int *)exitCode {
    XCTAssertTrue(([@[@"create", @"update"] containsObject:command]));
    return [self invokeCommand:command options:options exit:exitCode timeout:40 sharedReminderEntry:YES];
}

- (NSDictionary *)invokeCommand:(NSString *)command options:(NSArray<NSString *> *)options exit:(int *)exitCode
                       timeout:(NSTimeInterval)timeout sharedReminderEntry:(BOOL)sharedReminderEntry {
    NSString *tool = sharedReminderEntry ? @"apple-reminders" : @"apple-calendar";
    NSArray *args = [@[tool, command] arrayByAddingObjectsFromArray:options];
    XCTestExpectation *finished = [self expectationWithDescription:[@"native " stringByAppendingString:command]];
    __block NSDictionary *json;
    __block int status;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char **argv = calloc(args.count, sizeof(char *));
        for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup([args[i] UTF8String]);
        FILE *output = tmpfile();
        FILE *errors = tmpfile();
        // 独立 apple-reminders facade 直接委托这两个函数；故意绕过 apple-calendar 的外层校验。
        if (sharedReminderEntry) {
            status = [command isEqualToString:@"create"]
                ? calendar_cmd_remind((int)args.count, argv, fileno(output), fileno(errors), NO, NO)
                : calendar_cmd_update_reminder((int)args.count, argv, fileno(output), NO, NO);
        } else {
            status = calendar_offload_handle((int)args.count, argv, -1, fileno(output), fileno(errors));
        }
        lseek(fileno(output), 0, SEEK_SET);
        NSData *bytes = [[[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO] readDataToEndOfFile];
        json = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        fclose(output);
        fclose(errors);
        for (NSUInteger i = 0; i < args.count; i++) free(argv[i]);
        free(argv);
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:timeout];
    if (exitCode) *exitCode = status;
    XCTAssertNotNil(json);
    return json;
}

- (NSArray *)base:(NSString *)day {
    return @[@"--title", NSUUID.UUID.UUIDString, @"--calendar", self.testCalendar.title,
             @"--start", [day stringByAppendingString:@"T09:00:00Z"],
             @"--end", [day stringByAppendingString:@"T10:00:00Z"], @"--time-zone", @"Etc/UTC"];
}

- (NSArray<EKEvent *> *)eventsFrom:(NSString *)start to:(NSString *)end {
    [self.store reset];
    EKCalendar *calendar = [self.store calendarWithIdentifier:self.calendarID];
    XCTAssertNotNil(calendar);
    NSPredicate *predicate = [self.store predicateForEventsWithStartDate:noff_parse_date(start)
        endDate:noff_parse_date(end) calendars:@[calendar]];
    return [[self.store eventsMatchingPredicate:predicate]
            sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"startDate" ascending:YES]]];
}

- (NSDictionary *)check:(NSString *)start options:(NSArray *)options through:(NSString *)end expected:(NSArray *)expected {
    int status;
    NSDictionary *json = [self invoke:[[self base:start] arrayByAddingObjectsFromArray:options] exit:&status];
    XCTAssertEqual(status, 0, @"%@", json);
    XCTAssertEqualObjects(json[@"ok"], @YES);
    XCTAssertEqualObjects(json[@"data"][@"calendar"], self.testCalendar.title);
    NSArray *events = [self eventsFrom:[start stringByAppendingString:@"T00:00:00Z"] to:end];
    NSMutableArray *dates = [NSMutableArray array];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"yyyy-MM-dd";
    NSString *identifier = json[@"data"][@"id"];
    for (EKEvent *event in events) {
        if (![event.title isEqualToString:json[@"data"][@"title"]]) continue;
        [dates addObject:[formatter stringFromDate:event.startDate]];
        XCTAssertEqualWithAccuracy([event.endDate timeIntervalSinceDate:event.startDate], 3600, 0.1);
    }
    XCTAssertEqualObjects(dates, expected, @"Rule %@", options);
    EKEvent *saved = [self.store eventWithIdentifier:identifier];
    XCTAssertNotNil(saved);
    BOOL recurring = [json[@"data"][@"is_recurring"] boolValue];
    XCTAssertEqual(saved.hasRecurrenceRules, recurring);
    XCTAssertEqualObjects(json[@"data"][@"is_recurring"], @(recurring));
    if (recurring) {
        XCTAssertEqual(saved.recurrenceRules.count, 1u);
        EKRecurrenceRule *rule = saved.recurrenceRules.firstObject;
        NSDictionary *reported = [json[@"data"][@"recurrence_rules"] firstObject];
        NSArray *frequencies = @[@"daily", @"weekly", @"monthly", @"yearly"];
        XCTAssertEqualObjects(reported[@"frequency"], frequencies[rule.frequency]);
        XCTAssertEqualObjects(reported[@"interval"], @(rule.interval));
        NSUInteger countIndex = [options indexOfObject:@"--recurrence-count"];
        if (countIndex == NSNotFound) countIndex = [options indexOfObject:@"--recur-count"];
        if (countIndex != NSNotFound) {
            XCTAssertEqual(rule.recurrenceEnd.occurrenceCount, [options[countIndex + 1] integerValue]);
            XCTAssertEqualObjects(reported[@"end"][@"type"], @"count");
        } else if ([options containsObject:@"--recurrence-until"] || [options containsObject:@"--recur-until"]) {
            XCTAssertNotNil(rule.recurrenceEnd.endDate);
            XCTAssertEqualObjects(reported[@"end"][@"type"], @"until");
        } else {
            XCTAssertNil(rule.recurrenceEnd);
            XCTAssertEqualObjects(reported[@"end"][@"type"], @"never");
        }
        NSDictionary *fields = @{@"--recurrence-days-of-month": @"daysOfTheMonth",
            @"--recurrence-months-of-year": @"monthsOfTheYear", @"--recurrence-weeks-of-year": @"weeksOfTheYear",
            @"--recurrence-days-of-year": @"daysOfTheYear", @"--recurrence-set-positions": @"setPositions"};
        for (NSString *flag in fields) {
            NSUInteger index = [options indexOfObject:flag];
            if (index == NSNotFound) continue;
            NSMutableSet *numbers = [NSMutableSet set];
            for (NSString *number in [options[index + 1] componentsSeparatedByString:@","]) [numbers addObject:@(number.integerValue)];
            XCTAssertEqualObjects([NSSet setWithArray:[rule valueForKey:fields[flag]]], numbers);
        }
    }
    return json;
}

- (void)testSimpleFrequenciesAndIntervals {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-interval", @"2", @"--recurrence-count", @"3"] through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-03", @"2027-01-05"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"weekly", @"--recurrence-interval", @"2", @"--recurrence-count", @"3"] through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-15", @"2027-01-29"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"monthly", @"--recurrence-interval", @"2", @"--recurrence-count", @"3"] through:@"2027-08-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-03-01", @"2027-05-01"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"yearly", @"--recurrence-interval", @"2", @"--recurrence-count", @"2"] through:@"2030-01-02T00:00:00Z" expected:@[@"2027-01-01", @"2029-01-01"]];
}

- (void)testEveryWeekdayAndMultipleWeekdays {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"MO,TU,WE,TH,FR,SA,SU", @"--recurrence-count", @"7"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02", @"2027-01-03", @"2027-01-04", @"2027-01-05", @"2027-01-06", @"2027-01-07"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"TU,FR", @"--recurrence-count", @"4"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-05", @"2027-01-08", @"2027-01-12"]];
}

- (void)testMonthlyOrdinalWeekdays {
    [self check:@"2027-01-12" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"2TU", @"--recurrence-count", @"3"] through:@"2027-05-01T00:00:00Z" expected:@[@"2027-01-12", @"2027-02-09", @"2027-03-09"]];
    [self check:@"2027-01-26" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"-1TU", @"--recurrence-count", @"3"] through:@"2027-05-01T00:00:00Z" expected:@[@"2027-01-26", @"2027-02-23", @"2027-03-30"]];
}

- (void)testYearlyOrdinalWeekdays {
    [self check:@"2027-01-12" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-week", @"2TU", @"--recurrence-count", @"2"] through:@"2030-01-01T00:00:00Z" expected:@[@"2027-01-12", @"2028-01-11"]];
    [self check:@"2027-12-28" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-week", @"-1TU", @"--recurrence-count", @"2"] through:@"2030-01-01T00:00:00Z" expected:@[@"2027-12-28", @"2028-12-26"]];
}

- (void)testMonthDaysAndMissing31st {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"1,-1", @"--recurrence-count", @"4"] through:@"2027-06-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-31", @"2027-02-01", @"2027-02-28"]];
    [self check:@"2027-01-31" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"31", @"--recurrence-count", @"3"] through:@"2027-08-01T00:00:00Z" expected:@[@"2027-01-31", @"2027-03-31", @"2027-05-31"]];
}

- (void)testMonthsOfYear {
    [self check:@"2027-01-10" options:@[@"--recurrence", @"yearly", @"--recurrence-months-of-year", @"1,2", @"--recurrence-count", @"3"] through:@"2029-01-01T00:00:00Z" expected:@[@"2027-01-10", @"2027-02-10", @"2028-01-10"]];
}

- (void)testWeeksOfYear {
    [self check:@"2027-01-13" options:@[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"2,-2", @"--recurrence-days-of-week", @"WE", @"--recurrence-count", @"4"] through:@"2029-03-01T00:00:00Z" expected:@[@"2027-01-13", @"2027-12-22", @"2028-01-12", @"2028-12-20"]];
}

- (void)testDaysOfYearAndLeapYear {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-year", @"1,-1", @"--recurrence-count", @"3"] through:@"2029-01-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-12-31", @"2028-01-01"]];
    [self check:@"2027-03-01" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-year", @"60", @"--recurrence-count", @"2"] through:@"2029-01-01T00:00:00Z" expected:@[@"2027-03-01", @"2028-02-29"]];
}

- (void)testSetPositionsAcrossSelectors {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"MO,TU,WE,TH,FR", @"--recurrence-set-positions", @"1,-1", @"--recurrence-count", @"4"] through:@"2027-05-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-29", @"2027-02-01", @"2027-02-26"]];
    [self check:@"2027-12-31" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-year", @"1,100,-1", @"--recurrence-set-positions", @"-1", @"--recurrence-count", @"2"] through:@"2030-01-01T00:00:00Z" expected:@[@"2027-12-31", @"2028-12-31"]];
    [self check:@"2027-01-08" options:@[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"MO,FR", @"--recurrence-set-positions", @"-1", @"--recurrence-count", @"3"] through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-08", @"2027-01-15", @"2027-01-22"]];
    [self check:@"2027-01-15" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"1,15,-1", @"--recurrence-set-positions", @"2", @"--recurrence-count", @"2"] through:@"2027-04-01T00:00:00Z" expected:@[@"2027-01-15", @"2027-02-15"]];
    [self check:@"2027-02-10" options:@[@"--recurrence", @"yearly", @"--recurrence-months-of-year", @"1,2", @"--recurrence-set-positions", @"-1", @"--recurrence-count", @"2"] through:@"2029-03-01T00:00:00Z" expected:@[@"2027-02-10", @"2028-02-10"]];
    [self check:@"2027-12-22" options:@[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"2,-2", @"--recurrence-days-of-week", @"WE", @"--recurrence-set-positions", @"-1", @"--recurrence-count", @"2"] through:@"2029-03-01T00:00:00Z" expected:@[@"2027-12-22", @"2028-12-20"]];
}

- (void)testCombinedFilters {
    [self check:@"2027-01-04" options:@[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"1,2,3,4,5,6,7", @"--recurrence-days-of-week", @"MO", @"--recurrence-count", @"3"] through:@"2027-05-01T00:00:00Z" expected:@[@"2027-01-04", @"2027-02-01", @"2027-03-01"]];
    [self check:@"2027-02-09" options:@[@"--recurrence", @"yearly", @"--recurrence-months-of-year", @"2,3", @"--recurrence-days-of-week", @"2TU", @"--recurrence-count", @"3"] through:@"2029-01-01T00:00:00Z" expected:@[@"2027-02-09", @"2027-03-09", @"2028-02-08"]];
}

- (void)testEndConditionsAndExactBoundary {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily"] through:@"2027-01-05T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02", @"2027-01-03", @"2027-01-04"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-count", @"1"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02", @"2027-01-03"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03T09:00:00Z"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02", @"2027-01-03"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03T08:59:59Z"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02"]];
}

- (void)testTimeZoneAndDaylightSaving {
    NSArray *options = @[@"--title", @"DST", @"--calendar", self.testCalendar.title,
        @"--start", @"2027-03-13T09:00:00-05:00", @"--end", @"2027-03-13T10:00:00-05:00",
        @"--time-zone", @"America/New_York", @"--recurrence", @"daily", @"--recurrence-until", @"2027-03-15"];
    int status;
    NSDictionary *json = [self invoke:options exit:&status];
    XCTAssertEqual(status, 0, @"%@", json);
    NSArray *events = [self eventsFrom:@"2027-03-13T00:00:00Z" to:@"2027-03-18T00:00:00Z"];
    XCTAssertEqual(events.count, 3u);
    NSArray *expected = @[@"2027-03-13T14:00:00Z", @"2027-03-14T13:00:00Z", @"2027-03-15T13:00:00Z"];
    for (NSUInteger i = 0; i < expected.count; i++) XCTAssertEqualObjects([events[i] startDate], noff_parse_date(expected[i]));
}

- (void)testSingleEventRegression {
    NSDictionary *json = [self check:@"2027-01-01" options:@[@"--location", @"Lab", @"--notes", @"Regression", @"--alarm", @"15"] through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-01"]];
    EKEvent *saved = [self.store eventWithIdentifier:json[@"data"][@"id"]];
    XCTAssertEqualObjects(saved.location, @"Lab");
    XCTAssertEqualObjects(saved.notes, @"Regression");
    XCTAssertEqual(saved.alarms.firstObject.relativeOffset, -900);
    XCTAssertEqualObjects(json[@"data"][@"recurrence_rules"], @[]);
}

- (void)testInvalidRulesDoNotSave {
    NSArray *cases = @[
        @[@"--recurrence", @"hourly"], @[@"--recurrence"],
        @[@"--recurrence", @""], @[@"--recurrence", @"weekly", @"--recurrence", @"monthly"],
        @[@"--recurrence-interval", @"2"], @[@"--recurrence-typo", @"2"],
        @[@"--reccurence", @"weekly"],
        @[@"--recurrenc", @"weekly"],
        @[@"--recurrence", @"weekly", @"--recurrence-interval", @"0"],
        @[@"--recurrence", @"weekly", @"--recurrence-interval", @"-1"],
        @[@"--recurrence", @"weekly", @"--recurrence-interval", @"1.5"],
        @[@"--recurrence", @"weekly", @"--recurrence-interval", @"9223372036854775808"],
        @[@"--recurrence", @"daily", @"--recurrence-days-of-week", @"MO"],
        @[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"2MO"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"54MO"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"0MO"],
        @[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"XX"],
        @[@"--recurrence", @"weekly", @"--recurrence-days-of-week", @"MO,"],
        @[@"--recurrence", @"yearly", @"--recurrence-days-of-month", @"1"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"0"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"32"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-month", @"-32"],
        @[@"--recurrence", @"monthly", @"--recurrence-months-of-year", @"1"],
        @[@"--recurrence", @"yearly", @"--recurrence-months-of-year", @"13"],
        @[@"--recurrence", @"yearly", @"--recurrence-months-of-year", @"-1"],
        @[@"--recurrence", @"weekly", @"--recurrence-weeks-of-year", @"1"],
        @[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"54"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-year", @"1"],
        @[@"--recurrence", @"yearly", @"--recurrence-days-of-year", @"367"],
        @[@"--recurrence", @"monthly", @"--recurrence-set-positions", @"1"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"MO", @"--recurrence-set-positions", @"0"],
        @[@"--recurrence", @"monthly", @"--recurrence-days-of-week", @"MO", @"--recurrence-set-positions", @"-367"],
        @[@"--recurrence", @"daily", @"--recurrence-count", @"0"],
        @[@"--recurrence", @"daily", @"--recurrence-count", @"-2"],
        @[@"--recurrence", @"daily", @"--recurrence-count", @"2", @"--recurrence-until", @"2027-02-01"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"2026-12-31"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"2027-02-30"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"tomorrow"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"2027-02-30T09:00:00Z"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03T09:00:00Zjunk"],
        @[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03T09:00:00+25:00"],
        @[@"--recurrence", @"daily", @"--recurrence-count", @"9223372036854775808"]
    ];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self invoke:[[self base:@"2027-01-01"] arrayByAddingObjectsFromArray:options] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", options, json);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}

- (void)testBiweeklyMultipleWeekdays {
    [self check:@"2027-01-01" options:@[@"--recurrence", @"weekly", @"--recurrence-interval", @"2", @"--recurrence-days-of-week", @"TU,FR", @"--recurrence-count", @"4"] through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-12", @"2027-01-15", @"2027-01-26"]];
}

- (void)testYearlyBoundarySelectors {
    [self check:@"2028-12-31" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-year", @"366"] through:@"2031-12-31T23:59:59Z" expected:@[@"2028-12-31"]];
    [self check:@"2026-12-31" options:@[@"--recurrence", @"yearly", @"--recurrence-days-of-week", @"53TH"] through:@"2029-12-31T23:59:59Z" expected:@[@"2026-12-31"]];
    [self check:@"2026-12-30" options:@[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"53", @"--recurrence-days-of-week", @"WE"] through:@"2029-12-31T23:59:59Z" expected:@[@"2026-12-30"]];
}

- (void)testSelectorLikeNotesAreLiteral {
    [self check:@"2027-01-01" options:@[@"--notes", @"--recurrence"] through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01"]];
}

- (void)testTimeZoneOptionLikeValuesAreLiteral {
    for (NSString *field in @[@"--title", @"--notes", @"--location"]) {
        for (NSNumber *atEnd in @[@NO, @YES]) {
            NSMutableArray *options = [[self base:@"2027-01-01"] mutableCopy];
            [options removeObjectsInRange:NSMakeRange(options.count - 2, 2)];
            if ([field isEqualToString:@"--title"]) [options removeObjectsInRange:NSMakeRange(0, 2)];
            NSArray *literal = @[field, @"--time-zone"];
            if (atEnd.boolValue) [options addObjectsFromArray:literal];
            else [options insertObjects:literal atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
            int status;
            NSDictionary *json = [self invoke:options exit:&status];
            XCTAssertEqual(status, 0, @"%@", json);
            [self.store reset];
            EKEvent *saved = [self.store eventWithIdentifier:json[@"data"][@"id"]];
            XCTAssertNotNil(saved);
            NSString *property = [field substringFromIndex:2];
            XCTAssertEqualObjects([saved valueForKey:property], @"--time-zone");
        }
    }
    int status;
    NSDictionary *json = [self invoke:[[self base:@"2027-01-01"] arrayByAddingObjectsFromArray:@[@"--notes", @"--time-zone"]] exit:&status];
    XCTAssertEqual(status, 0, @"%@", json);
    XCTAssertEqualObjects(json[@"data"][@"time_zone"], [NSTimeZone timeZoneWithName:@"Etc/UTC"].name);
}

- (void)testOtherOptionLikeTextValuesAreLiteral {
    NSArray *literals = @[@"--calendar", @"--title", @"--notes", @"--location", @"--alarm",
        @"--start", @"--end", @"--recurrence", @"--recur", @"--recur-days", @"--help", @"--compact", @"--quiet"];
    for (NSString *literal in literals) {
        for (NSString *field in @[@"--title", @"--notes", @"--location"]) {
            for (NSNumber *atEnd in @[@NO, @YES]) {
                NSMutableArray *options = [[self base:@"2027-01-01"] mutableCopy];
                if ([field isEqualToString:@"--title"]) [options removeObjectsInRange:NSMakeRange(0, 2)];
                NSArray *pair = @[field, literal];
                if (atEnd.boolValue) [options addObjectsFromArray:pair];
                else [options insertObjects:pair atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
                int status;
                NSDictionary *json = [self invoke:options exit:&status];
                XCTAssertEqual(status, 0, @"%@ returned %@", options, json);
                XCTAssertEqualObjects(json[@"data"][@"calendar"], self.testCalendar.title);
                [self.store reset];
                EKEvent *event = [self.store eventWithIdentifier:json[@"data"][@"id"]];
                XCTAssertNotNil(event);
                XCTAssertEqualObjects([event valueForKey:[field substringFromIndex:2]], literal);
                XCTAssertFalse(event.hasRecurrenceRules);
            }
        }
    }
}

- (void)testEndConditionsForEveryFrequency {
    NSArray *frequencies = @[@"daily", @"weekly", @"monthly", @"yearly"];
    NSArray *secondDates = @[@"2027-01-02", @"2027-01-08", @"2027-02-01", @"2028-01-01"];
    NSArray *thirdDates = @[@"2027-01-03", @"2027-01-15", @"2027-03-01", @"2029-01-01"];
    for (NSUInteger i = 0; i < frequencies.count; i++) {
        [self check:@"2027-01-01" options:@[@"--recurrence", frequencies[i], @"--recurrence-until", secondDates[i]] through:@"2030-01-01T00:00:00Z" expected:@[@"2027-01-01", secondDates[i]]];
        [self check:@"2027-01-01" options:@[@"--recurrence", frequencies[i]] through:[thirdDates[i] stringByAppendingString:@"T00:00:00Z"] expected:@[@"2027-01-01", secondDates[i]]];
    }
}

// 与产品实现无关的原生对照；保留明确日期断言，不能把系统失败算作产品验收通过。
- (void)testNativeWeekNumberReference {
    EKEvent *native = [EKEvent eventWithEventStore:self.store];
    native.calendar = [self.store calendarWithIdentifier:self.calendarID];
    native.title = @"Native week reference";
    native.startDate = noff_parse_date(@"2027-01-13T09:00:00Z");
    native.endDate = noff_parse_date(@"2027-01-13T10:00:00Z");
    native.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    [native addRecurrenceRule:[[EKRecurrenceRule alloc] initRecurrenceWithFrequency:EKRecurrenceFrequencyYearly interval:1 daysOfTheWeek:@[[EKRecurrenceDayOfWeek dayOfWeek:EKWednesday]] daysOfTheMonth:nil monthsOfTheYear:nil weeksOfTheYear:@[@2, @(-2)] daysOfTheYear:nil setPositions:nil end:[EKRecurrenceEnd recurrenceEndWithOccurrenceCount:4]]];
    NSError *error = nil;
    XCTAssertTrue([self.store saveEvent:native span:EKSpanThisEvent commit:YES error:&error], @"%@", error);
    NSMutableArray *dates = [NSMutableArray array];
    for (EKEvent *event in [self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2029-03-01T00:00:00Z"]) {
        if ([event.title isEqualToString:@"Native week reference"]) [dates addObject:event.startDate];
    }
    NSArray *expected = @[noff_parse_date(@"2027-01-13T09:00:00Z"), noff_parse_date(@"2027-12-22T09:00:00Z"), noff_parse_date(@"2028-01-12T09:00:00Z"), noff_parse_date(@"2028-12-20T09:00:00Z")];
    XCTAssertEqualObjects(dates, expected, @"Direct EventKit control: the native week-number expansion must work before accepting full recurrence support.");
}

- (void)testPositiveWeeksOfYear {
    [self check:@"2027-01-13" options:@[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"2", @"--recurrence-days-of-week", @"WE", @"--recurrence-count", @"3"] through:@"2030-01-01T00:00:00Z" expected:@[@"2027-01-13", @"2028-01-12", @"2029-01-10"]];
}

// M1：找不到的日历不回退默认日历，错误信息列出候选名称，且不保存。
- (void)testUnknownCalendarDoesNotFallBack {
    NSArray *options = @[@"--title", @"Must not save", @"--calendar", NSUUID.UUID.UUIDString,
        @"--start", @"2027-01-01T09:00:00Z", @"--end", @"2027-01-01T10:00:00Z",
        @"--recurrence", @"weekly"];
    int status;
    NSDictionary *json = [self invoke:options exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS);
    XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    XCTAssertTrue([json[@"error"][@"message"] containsString:self.testCalendar.title], @"%@", json);
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}

- (void)testDefaultTimeZoneCompatibility {
    NSArray *base = @[@"--title", @"Default zone", @"--calendar", self.testCalendar.title,
        @"--start", @"2027-01-01T09:00:00Z", @"--end", @"2027-01-01T10:00:00Z"];
    int status;
    NSDictionary *single = [self invoke:base exit:&status];
    XCTAssertEqual(status, 0);
    // 对照旧创建路径：不主动写 timeZone，让 EventKit 自行决定默认值。
    EKEvent *legacy = [EKEvent eventWithEventStore:self.store];
    legacy.calendar = [self.store calendarWithIdentifier:self.calendarID];
    legacy.title = @"Legacy default zone reference";
    legacy.startDate = noff_parse_date(@"2027-01-01T09:00:00Z");
    legacy.endDate = noff_parse_date(@"2027-01-01T10:00:00Z");
    NSError *error = nil;
    XCTAssertTrue([self.store saveEvent:legacy span:EKSpanThisEvent commit:YES error:&error], @"%@", error);
    XCTAssertEqualObjects(single[@"data"][@"time_zone"], legacy.timeZone.name ?: NSNull.null);
    NSDictionary *recurring = [self invoke:[base arrayByAddingObjectsFromArray:@[@"--recurrence", @"weekly"]] exit:&status];
    XCTAssertEqual(status, 0);
    XCTAssertEqualObjects(recurring[@"data"][@"time_zone"], NSTimeZone.localTimeZone.name);
}

- (void)testInvalidDatesAndTimeZonesDoNotSave {
    NSArray *base = @[@"--title", @"Invalid", @"--calendar", self.testCalendar.title,
        @"--start", @"2027-01-01T09:00:00Z"];
    NSArray *cases = @[
        @[@"--end", @"2027-01-01T10:00:00Z", @"--time-zone", @"Mars/Olympus"],
        @[@"--end", @"2027-01-01T10:00:00Z", @"--time-zone"],
        @[@"--end", @"2027-01-01T09:00:00Z"],
        @[@"--end", @"2027-01-01T08:00:00Z"],
        @[@"--end", @"2027-01-01T10:00:00Z", @"--recurrence-days-of-week", @"MO"]
    ];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self invoke:[base arrayByAddingObjectsFromArray:options] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", json);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}

- (void)testUpstreamFrequencyAliases {
    NSDictionary *cases = @{@"day": @"2027-01-02", @"WEEK": @"2027-01-08",
        @"month": @"2027-02-01", @"year": @"2028-01-01", @"annually": @"2028-01-01"};
    for (NSString *frequency in cases) {
        NSDictionary *json = [self check:@"2027-01-01"
            options:@[@"--recur", frequency, @"--recur-count", @"2"]
            through:@"2029-01-01T00:00:00Z" expected:@[@"2027-01-01", cases[frequency]]];
        NSDictionary *summary = json[@"data"][@"recurrence"];
        NSDictionary *complete = [json[@"data"][@"recurrence_rules"] firstObject];
        XCTAssertEqualObjects(summary[@"frequency"], complete[@"frequency"]);
        XCTAssertEqualObjects(summary[@"count"], @2);
        XCTAssertEqualObjects(summary[@"interval"], @1);
    }
}

- (void)testUpstreamWeekdayAliasesAndListReadback {
    NSDictionary *json = [self check:@"2027-01-01"
        options:@[@"--recur", @"weekly", @"--recur-interval", @"2", @"--recur-days", @"TU, friday", @"--recur-count", @"4"]
        through:@"2027-03-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-12", @"2027-01-15", @"2027-01-26"]];
    XCTAssertEqualObjects(json[@"data"][@"recurrence"][@"days_of_week"], (@[@"tue", @"fri"]));
    int status;
    NSDictionary *listed = [self invokeCommand:@"list" options:@[@"--calendar", self.testCalendar.title,
        @"--start", @"2027-01-01T00:00:00Z", @"--end", @"2027-03-01T00:00:00Z"] exit:&status];
    XCTAssertEqual(status, 0, @"%@", listed);
    NSArray *events = listed[@"data"][@"events"];
    XCTAssertEqual(events.count, 4u);
    for (NSDictionary *event in events) {
        XCTAssertEqualObjects(event[@"recurrence"], json[@"data"][@"recurrence"]);
        XCTAssertEqualObjects(event[@"recurrence_rules"], json[@"data"][@"recurrence_rules"]);
        XCTAssertEqualObjects(event[@"time_zone"], json[@"data"][@"time_zone"]);
    }
}

- (void)testUntilFamiliesKeepTheirBoundarySemantics {
    [self check:@"2027-01-01" options:@[@"--recur", @"daily", @"--recur-until", @"2027-01-03T00:00:00Z"]
        through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-03"]
        through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01", @"2027-01-02", @"2027-01-03"]];
    [self check:@"2027-01-01" options:@[@"--recurrence", @"daily", @"--recurrence-until", @"2027-01-01T09:00:00Z"]
        through:@"2027-02-01T00:00:00Z" expected:@[@"2027-01-01"]];
    int status;
    NSDictionary *rejected = [self invoke:[[self base:@"2027-01-01"] arrayByAddingObjectsFromArray:
        @[@"--recur", @"daily", @"--recur-until", @"2027-01-01T09:00:00Z"]] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", rejected);
}

- (void)testMixedAndMalformedUpstreamOptionsDoNotSave {
    NSArray *cases = @[
        @[@"--recurrence", @"weekly", @"--recur", @"weekly"],
        @[@"--recurrence", @"monthly", @"--recur-count", @"2"],
        @[@"--recur", @"monthly", @"--recurrence-days-of-month", @"1"],
        @[@"--recur"], @[@"--recur", @""], @[@"--recur-days", @"fri"],
        @[@"--recur", @"daily", @"--recur", @"weekly"],
        @[@"--recur", @"daily", @"--recur-day", @"fri"],
        @[@"--recur", @"daily", @"--recur-days", @"fri"],
        @[@"--recur", @"daily", @"--recur-count", @"2", @"--recur-until", @"2027-02-01T00:00:00Z"]
    ];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self invoke:[[self base:@"2027-01-01"] arrayByAddingObjectsFromArray:options] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", options, json);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}

- (void)testYearWeekWarningSurvivesCreateAndList {
    int status;
    NSDictionary *json = [self invoke:[[self base:@"2027-01-13"] arrayByAddingObjectsFromArray:
        @[@"--recurrence", @"yearly", @"--recurrence-weeks-of-year", @"2", @"--recurrence-days-of-week", @"WE"]] exit:&status];
    XCTAssertEqual(status, 0, @"%@", json);
    XCTAssertGreaterThan([json[@"data"][@"warnings"] count], 0u);
    NSDictionary *listed = [self invokeCommand:@"list" options:@[@"--calendar", self.testCalendar.title,
        @"--start", @"2027-01-01T00:00:00Z", @"--end", @"2027-02-01T00:00:00Z"] exit:&status];
    XCTAssertEqual(status, 0);
    NSDictionary *event = [listed[@"data"][@"events"] firstObject];
    XCTAssertNotNil(event);
    XCTAssertEqualObjects(event[@"warnings"], json[@"data"][@"warnings"]);
    // 此处仅验证警告没有丢失；后续日期是否展开仍由原来的失败断言独立检查。
}

- (NSString *)createReminderTestList {
    XCTestExpectation *access = [self expectationWithDescription:@"reminder access"];
    [self.store requestFullAccessToRemindersWithCompletion:^(BOOL granted, NSError *error) {
        XCTAssertTrue(granted, @"Grant simulator reminder permission to com.openminis.app: %@", error);
        [access fulfill];
    }];
    [self waitForExpectations:@[access] timeout:15];
    EKSource *source = self.store.defaultCalendarForNewReminders.source;
    if (!source) {
        for (EKSource *candidate in self.store.sources) {
            if (candidate.sourceType == EKSourceTypeLocal) { source = candidate; break; }
        }
    }
    XCTAssertNotNil(source);
    EKCalendar *list = [EKCalendar calendarForEntityType:EKEntityTypeReminder eventStore:self.store];
    list.title = [@"MinisX-Reminder-Test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    list.source = source;
    NSError *error = nil;
    XCTAssertTrue([self.store saveCalendar:list commit:YES error:&error], @"%@", error);
    self.reminderCalendarID = list.calendarIdentifier;
    XCTestExpectation *propagated = [self expectationWithDescription:@"reminder list propagation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [propagated fulfill]; });
    [self waitForExpectations:@[propagated] timeout:2];
    return [list.title copy];
}

- (NSArray<EKReminder *> *)remindersInTestList {
    [self.store reset];
    EKCalendar *list = [self.store calendarWithIdentifier:self.reminderCalendarID];
    XCTAssertNotNil(list);
    NSPredicate *predicate = [self.store predicateForRemindersInCalendars:@[list]];
    XCTestExpectation *fetched = [self expectationWithDescription:@"read isolated reminder list"];
    __block NSArray<EKReminder *> *reminders = nil;
    [self.store fetchRemindersMatchingPredicate:predicate completion:^(NSArray<EKReminder *> *result) {
        reminders = result;
        [fetched fulfill];
    }];
    [self waitForExpectations:@[fetched] timeout:10];
    XCTAssertNotNil(reminders);
    return reminders;
}

- (void)testReminderEntrypointsRejectCalendarRecurrenceWithoutMutation {
    NSString *listName = [self createReminderTestList];
    int status;
    NSDictionary *seed = [self invokeReminderCommand:@"create" options:@[@"--title", @"Keep reminder",
        @"--list", listName, @"--due", @"2027-01-01T09:00:00Z", @"--notes", @"Keep notes",
        @"--recur", @"weekly", @"--recur-count", @"3"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", seed);
    XCTAssertEqualObjects(seed[@"data"][@"list"], listName);
    NSString *identifier = seed[@"data"][@"id"];
    XCTAssertEqual([self remindersInTestList].count, 1u);
    NSArray *cases = @[
        @[@"--recurrence", @"weekly"], @[@"--recurrence-count", @"3"],
        @[@"--recurrence-unknown", @"weekly"], @[@"--recurrence"],
        @[@"--recur", @"weekly", @"--recurrence-count", @"3"],
        @[@"--recur-unknown", @"--recurrence", @"weekly"]
    ];
    for (NSNumber *shared in @[@NO, @YES]) {
        for (NSArray *options in cases) {
            NSArray *create = [@[@"--title", @"Must not create", @"--list", listName,
                @"--due", @"2027-01-01T09:00:00Z"] arrayByAddingObjectsFromArray:options];
            NSDictionary *rejected = shared.boolValue
                ? [self invokeReminderCommand:@"create" options:create exit:&status]
                : [self invokeCommand:@"remind" options:create exit:&status];
            XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", create, rejected);
            XCTAssertEqualObjects(rejected[@"error"][@"code"], @"invalid_args");
            XCTAssertEqual([self remindersInTestList].count, 1u, @"Rejected create must not save a reminder.");

            NSArray *update = [@[@"--id", identifier, @"--title", @"Must not change",
                @"--notes", @"Must not change notes", @"--clear-recur"] arrayByAddingObjectsFromArray:options];
            rejected = shared.boolValue
                ? [self invokeReminderCommand:@"update" options:update exit:&status]
                : [self invokeCommand:@"update-reminder" options:update exit:&status];
            XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", update, rejected);
            XCTAssertEqualObjects(rejected[@"error"][@"code"], @"invalid_args");
            NSArray<EKReminder *> *stored = [self remindersInTestList];
            XCTAssertEqual(stored.count, 1u);
            EKReminder *unchanged = stored.firstObject;
            XCTAssertEqualObjects(unchanged.calendarItemIdentifier, identifier);
            XCTAssertEqualObjects(unchanged.title, @"Keep reminder");
            XCTAssertEqualObjects(unchanged.notes, @"Keep notes");
            XCTAssertEqual(unchanged.recurrenceRules.count, 1u);
            XCTAssertEqual(unchanged.recurrenceRules.firstObject.frequency, EKRecurrenceFrequencyWeekly);
            XCTAssertEqual(unchanged.recurrenceRules.firstObject.recurrenceEnd.occurrenceCount, 3u);
        }
    }
}

- (void)testReminderRecurrenceOptionLikeTextRemainsLiteral {
    NSString *listName = [self createReminderTestList];
    for (NSNumber *shared in @[@NO, @YES]) {
        int status;
        NSArray *create = @[@"--title", @"--recurrence", @"--notes", @"--recurrence-count", @"--list", listName,
            @"--due", @"2027-01-01T09:00:00Z", @"--recur", @"weekly", @"--recur-count", @"2"];
        NSDictionary *created = shared.boolValue
            ? [self invokeReminderCommand:@"create" options:create exit:&status]
            : [self invokeCommand:@"remind" options:create exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", created);
        XCTAssertEqualObjects(created[@"data"][@"list"], listName);
        NSString *identifier = created[@"data"][@"id"];
        [self.store reset];
        EKReminder *saved = (EKReminder *)[self.store calendarItemWithIdentifier:identifier];
        XCTAssertEqualObjects(saved.title, @"--recurrence");
        XCTAssertEqualObjects(saved.notes, @"--recurrence-count");
        XCTAssertEqual(saved.recurrenceRules.firstObject.recurrenceEnd.occurrenceCount, 2u);
        NSArray *update = @[@"--id", identifier, @"--title", @"--recurrence-days-of-week",
            @"--notes", @"--recurrence-until", @"--recur", @"monthly", @"--recur-count", @"3"];
        NSDictionary *updated = shared.boolValue
            ? [self invokeReminderCommand:@"update" options:update exit:&status]
            : [self invokeCommand:@"update-reminder" options:update exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
        [self.store reset];
        saved = (EKReminder *)[self.store calendarItemWithIdentifier:identifier];
        XCTAssertEqualObjects(saved.title, @"--recurrence-days-of-week");
        XCTAssertEqualObjects(saved.notes, @"--recurrence-until");
        XCTAssertEqual(saved.recurrenceRules.firstObject.frequency, EKRecurrenceFrequencyMonthly);
        XCTAssertEqual(saved.recurrenceRules.firstObject.recurrenceEnd.occurrenceCount, 3u);
    }
    XCTAssertEqual([self remindersInTestList].count, 2u);
}

- (void)testUpstreamReminderRecurrenceCreateUpdateAndClear {
    NSString *listName = [self createReminderTestList];
    int status;
    NSDictionary *created = [self invokeCommand:@"remind" options:@[@"--title", @"Reminder regression",
        @"--list", listName, @"--due", @"2027-01-01T09:00:00Z", @"--recur", @"week",
        @"--recur-days", @"fri", @"--recur-count", @"3", @"--notes", @"Keep notes"] exit:&status];
    XCTAssertEqual(status, 0, @"%@", created);
    NSString *identifier = created[@"data"][@"id"];
    XCTAssertEqualObjects(created[@"data"][@"list"], listName);
    XCTAssertEqualObjects(created[@"data"][@"recurrence"][@"frequency"], @"weekly");
    XCTAssertEqualObjects(created[@"data"][@"recurrence"][@"count"], @3);
    [self.store reset];
    EKReminder *saved = (EKReminder *)[self.store calendarItemWithIdentifier:identifier];
    XCTAssertEqualObjects(saved.calendar.calendarIdentifier, self.reminderCalendarID);
    XCTAssertEqual(saved.recurrenceRules.firstObject.frequency, EKRecurrenceFrequencyWeekly);
    XCTAssertEqualObjects(saved.notes, @"Keep notes");
    NSDictionary *updated = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier,
        @"--recur", @"month", @"--recur-count", @"2"] exit:&status];
    XCTAssertEqual(status, 0, @"%@", updated);
    XCTAssertEqualObjects(updated[@"data"][@"recurrence"][@"frequency"], @"monthly");
    XCTAssertEqualObjects(updated[@"data"][@"recurrence"][@"count"], @2);
    NSDictionary *cleared = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--clear-recur"] exit:&status];
    XCTAssertEqual(status, 0, @"%@", cleared);
    XCTAssertNil(cleared[@"data"][@"recurrence"]);
    [self.store reset];
    saved = (EKReminder *)[self.store calendarItemWithIdentifier:identifier];
    XCTAssertFalse(saved.hasRecurrenceRules);
    XCTAssertEqualObjects(saved.notes, @"Keep notes");
}

- (void)testNonCreateRejectsRecurrenceOptions {
    for (NSString *command in @[@"list", @"update", @"remind"]) {
        int status;
        NSDictionary *json = [self invokeCommand:command options:@[@"--recurrence", @"weekly"] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}

#pragma mark - 全天事件、提醒通知、名称匹配与归属

- (NSDate *)localDay:(NSString *)day {
    return noff_parse_date(day);
}

// 结束日 23:59:59（当地）。
- (NSDate *)localEndOfDay:(NSString *)day {
    NSDate *next = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:[self localDay:day] options:0];
    return [next dateByAddingTimeInterval:-1];
}

- (EKEvent *)savedEvent:(NSString *)identifier {
    [self.store reset];
    EKEvent *event = [self.store eventWithIdentifier:identifier];
    XCTAssertNotNil(event);
    return event;
}

- (NSDictionary *)createEvent:(NSArray *)options {
    int status;
    NSDictionary *json = [self invoke:[@[@"--title", NSUUID.UUID.UUIDString, @"--calendar", self.testCalendar.title]
        arrayByAddingObjectsFromArray:options] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", json);
    return json;
}

- (NSUInteger)eventCountInTestCalendar {
    return [self eventsFrom:@"2027-01-01T00:00:00" to:@"2029-01-01T00:00:00"].count;
}

// D1、D2、D7：--all-day 单天忽略时刻；纯日期跨 3 天包含结束日；create 与 list 都返回 is_all_day。
- (void)testAllDayCreateSingleAndMultiDay {
    NSDictionary *single = [self createEvent:@[@"--start", @"2027-03-10T14:30:00", @"--end", @"2027-03-10T15:30:00", @"--all-day"]];
    XCTAssertEqualObjects(single[@"data"][@"is_all_day"], @YES);
    XCTAssertEqualObjects(single[@"data"][@"time_zone"], NSNull.null);
    EKEvent *saved = [self savedEvent:single[@"data"][@"id"]];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-03-10"]);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-03-10"]);

    NSDictionary *multi = [self createEvent:@[@"--start", @"2027-12-01", @"--end", @"2027-12-03"]];
    XCTAssertEqualObjects(multi[@"data"][@"is_all_day"], @YES);
    saved = [self savedEvent:multi[@"data"][@"id"]];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-12-01"]);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-12-03"]);

    // 单天：起止写同一天的纯日期。
    NSDictionary *sameDay = [self createEvent:@[@"--start", @"2027-12-05", @"--end", @"2027-12-05"]];
    saved = [self savedEvent:sameDay[@"data"][@"id"]];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-12-05"]);

    // 只有一端是纯日期且没有 --all-day 时仍是定时事件。
    NSDictionary *timed = [self createEvent:@[@"--start", @"2027-12-07", @"--end", @"2027-12-08T10:00:00"]];
    XCTAssertEqualObjects(timed[@"data"][@"is_all_day"], @NO);

    int status;
    NSDictionary *listed = [self invokeCommand:@"list" options:@[@"--calendar", self.testCalendar.title,
        @"--start", @"2027-12-01", @"--end", @"2027-12-04"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", listed);
    NSArray *events = listed[@"data"][@"events"];
    XCTAssertEqual(events.count, 1u);
    XCTAssertEqualObjects(events.firstObject[@"is_all_day"], @YES);
    XCTAssertEqualObjects(events.firstObject[@"id"], multi[@"data"][@"id"]);
}

// D3、D4：结束日早于开始日、全天加 --time-zone 都是 invalid_args，且不保存。
- (void)testAllDayInvalidCombinationsDoNotSave {
    NSArray *cases = @[
        @[@"--start", @"2027-12-03", @"--end", @"2027-12-01"],
        @[@"--start", @"2027-12-03T10:00:00", @"--end", @"2027-12-01T10:00:00", @"--all-day"],
        @[@"--start", @"2027-12-01", @"--end", @"2027-12-03", @"--time-zone", @"Etc/UTC"],
        @[@"--start", @"2027-12-01T09:00:00", @"--end", @"2027-12-01T10:00:00", @"--all-day", @"--time-zone", @"Asia/Shanghai"],
    ];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self invoke:[@[@"--title", @"Must not save", @"--calendar", self.testCalendar.title]
            arrayByAddingObjectsFromArray:options] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", options, json);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventCountInTestCalendar], 0u);
}

// D5：全天事件可与两套重复参数组合；--recurrence-until 取当地整天。
- (void)testAllDayRecurringEvents {
    NSArray *families = @[
        @[@"--recurrence", @"weekly", @"--recurrence-count", @"3"],
        @[@"--recur", @"weekly", @"--recur-count", @"3"],
        @[@"--recurrence", @"weekly", @"--recurrence-until", @"2027-03-24"],
    ];
    for (NSArray *family in families) {
        NSDictionary *json = [self createEvent:[@[@"--start", @"2027-03-10", @"--end", @"2027-03-10"] arrayByAddingObjectsFromArray:family]];
        XCTAssertEqualObjects(json[@"data"][@"is_all_day"], @YES);
        XCTAssertEqualObjects(json[@"data"][@"is_recurring"], @YES);
        int status;
        NSDictionary *listed = [self invokeCommand:@"list" options:@[@"--calendar", self.testCalendar.title,
            @"--start", @"2027-03-01", @"--end", @"2027-04-30"] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", listed);
        NSMutableArray *starts = [NSMutableArray array];
        for (NSDictionary *event in listed[@"data"][@"events"]) {
            if (![event[@"id"] isEqualToString:json[@"data"][@"id"]]) continue;
            XCTAssertEqualObjects(event[@"is_all_day"], @YES);
            [starts addObject:event[@"start"]];
        }
        NSArray *expected = @[noff_format_date([self localDay:@"2027-03-10"]), noff_format_date([self localDay:@"2027-03-17"]),
                              noff_format_date([self localDay:@"2027-03-24"])];
        XCTAssertEqualObjects(starts, expected, @"%@", family);
        // 清理本轮创建的系列，避免下一轮的列表混入。
        [self.store reset];
        NSError *error = nil;
        EKEvent *master = [self.store eventWithIdentifier:json[@"data"][@"id"]];
        XCTAssertTrue([self.store removeEvent:master span:EKSpanFutureEvents commit:YES error:&error], @"%@", error);
    }
}

// D6：定时 -> 全天、全天 -> 全天、全天 -> 定时；只改标题不改变全天状态。
- (void)testAllDayUpdateSwitching {
    NSDictionary *created = [self createEvent:@[@"--start", @"2027-05-03T09:00:00", @"--end", @"2027-05-03T10:00:00"]];
    NSString *identifier = created[@"data"][@"id"];
    int status;

    // 定时 -> 全天（纯日期）；只传开始日，结束日沿用原来的日期（同一天）。
    NSDictionary *updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--start", @"2027-05-03"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    XCTAssertEqualObjects(updated[@"data"][@"is_all_day"], @YES);
    EKEvent *saved = [self savedEvent:identifier];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-05-03"]);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-05-03"]);

    // 只改标题：全天状态与日期不变。
    updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Renamed"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    XCTAssertEqualObjects(updated[@"data"][@"is_all_day"], @YES);
    saved = [self savedEvent:identifier];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.title, @"Renamed");
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-05-03"]);

    // 全天 -> 全天：换成新的日期范围。
    updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--start", @"2027-05-10", @"--end", @"2027-05-12"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    saved = [self savedEvent:identifier];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-05-10"]);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-05-12"]);

    // 结束日早于开始日：invalid_args，事件不变。
    updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Bad", @"--end", @"2027-05-01"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", updated);
    saved = [self savedEvent:identifier];
    XCTAssertEqualObjects(saved.title, @"Renamed");
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-05-12"]);

    // 无法解析的日期（含不存在的日期）：invalid_args，事件保持全天且不变。
    for (NSString *badDate in @[@"foo", @"2027-02-30"]) {
        updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--start", badDate] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ %@", badDate, updated);
        saved = [self savedEvent:identifier];
        XCTAssertTrue(saved.isAllDay, @"%@", badDate);
        XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-05-10"], @"%@", badDate);
    }

    // 全天 -> 定时：回读的起止等于传入的时刻。
    updated = [self invokeCommand:@"update" options:@[@"--id", identifier,
        @"--start", @"2027-05-10T14:00:00", @"--end", @"2027-05-10T15:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    XCTAssertEqualObjects(updated[@"data"][@"is_all_day"], @NO);
    saved = [self savedEvent:identifier];
    XCTAssertFalse(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, noff_parse_date(@"2027-05-10T14:00:00"));
    XCTAssertEqualObjects(saved.endDate, noff_parse_date(@"2027-05-10T15:00:00"));

    // 单独的 --all-day：按现有起止取整为全天。
    updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--all-day"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    saved = [self savedEvent:identifier];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-05-10"]);
    XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-05-10"]);
}

// D4、D6：绑定了其他时区的定时重复系列转为全天后，仍是当地的同一天，且不再带时区。
// 回归：曾按原时区解释整天范围，东京时区的事件转全天后多跨一天。
- (void)testAllDayUpdateClearsEventTimeZone {
    NSDictionary *created = [self createEvent:@[@"--start", @"2027-06-07T10:00:00+09:00", @"--end", @"2027-06-07T11:00:00+09:00",
        @"--time-zone", @"Asia/Tokyo", @"--recurrence", @"weekly", @"--recurrence-count", @"3"]];
    NSString *identifier = created[@"data"][@"id"];
    int status;
    NSDictionary *updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--all-day", @"--span", @"all"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    EKEvent *saved = [self savedEvent:identifier];
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *day = [calendar startOfDayForDate:noff_parse_date(@"2027-06-07T10:00:00+09:00")];
    XCTAssertTrue(saved.isAllDay);
    XCTAssertNil(saved.timeZone);
    XCTAssertEqualObjects(saved.startDate, day);
    XCTAssertEqualObjects(saved.endDate, [[calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0] dateByAddingTimeInterval:-1]);
}

// M3：事件命令拒绝提醒专用参数，给出事件的正确写法，且不保存、不改动；同名文本作为取值时照常使用。
- (void)testEventCommandsRejectReminderOptions {
    NSDictionary *expectedHints = @{@"--notify": @"--alarm", @"--due": @"--alarm", @"--list": @"--calendar", @"--list-id": @"--calendar-id",
                                    @"--priority": @"no priority", @"--lat": @"--location", @"--lng": @"--location",
                                    @"--location-name": @"--location", @"--radius": @"--location", @"--proximity": @"--location"};
    NSDictionary *values = @{@"--notify": @"on", @"--due": @"2027-07-01T09:00:00", @"--list": @"Work", @"--list-id": @"ABC", @"--priority": @"1",
                             @"--lat": @"22.6", @"--lng": @"114.0", @"--location-name": @"Office", @"--radius": @"200",
                             @"--proximity": @"enter"};
    NSUInteger before = [self eventCountInTestCalendar];
    int status;
    for (NSString *option in expectedHints) {
        NSDictionary *json = [self invoke:@[@"--title", @"Rejected", @"--calendar", self.testCalendar.title,
            @"--start", @"2027-07-01T09:00:00", @"--end", @"2027-07-01T10:00:00", option, values[option]] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ %@", option, json);
        NSString *message = json[@"error"][@"message"];
        XCTAssertTrue([message containsString:option], @"%@", message);
        XCTAssertTrue([message containsString:expectedHints[option]], @"%@", message);
    }
    XCTAssertEqual([self eventCountInTestCalendar], before);

    NSDictionary *created = [self createEvent:@[@"--start", @"2027-07-02T09:00:00", @"--end", @"2027-07-02T10:00:00",
        @"--notes", @"--notify on"]];
    NSString *identifier = created[@"data"][@"id"];
    XCTAssertEqualObjects([self savedEvent:identifier].notes, @"--notify on");
    XCTAssertEqual([self savedEvent:identifier].alarms.count, 0u);

    NSDictionary *updated = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed",
        @"--notify", @"on"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", updated);
    XCTAssertNotEqualObjects([self savedEvent:identifier].title, @"Changed");
}

- (NSArray<EKAlarm *> *)timeAlarms:(EKReminder *)reminder {
    NSMutableArray *alarms = [NSMutableArray array];
    for (EKAlarm *alarm in reminder.alarms) if (alarm.absoluteDate) [alarms addObject:alarm];
    return alarms;
}

- (EKReminder *)savedReminder:(NSString *)identifier {
    [self.store reset];
    EKReminder *reminder = (EKReminder *)[self.store calendarItemWithIdentifier:identifier];
    XCTAssertNotNil(reminder);
    return reminder;
}

- (NSDictionary *)createReminder:(NSString *)list options:(NSArray *)options exit:(int *)status {
    return [self invokeCommand:@"remind" options:[@[@"--title", NSUUID.UUID.UUIDString, @"--list", list]
        arrayByAddingObjectsFromArray:options] exit:status];
}

// R1、R2、R6、R7、R5：纯日期是全天无通知；带时刻和相对时间有通知；--notify 覆盖默认。
- (void)testReminderAllDayAndDefaultNotification {
    NSString *list = [self createReminderTestList];
    int status;
    NSDictionary *dateOnly = [self createReminder:list options:@[@"--due", @"2027-02-03"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", dateOnly);
    XCTAssertEqualObjects(dateOnly[@"data"][@"is_all_day"], @YES);
    XCTAssertEqualObjects(dateOnly[@"data"][@"due"], @"2027-02-03");
    XCTAssertEqualObjects(dateOnly[@"data"][@"notify"], @NO);
    XCTAssertNil(dateOnly[@"data"][@"notify_at"]);
    EKReminder *saved = [self savedReminder:dateOnly[@"data"][@"id"]];
    XCTAssertEqual(saved.dueDateComponents.hour, NSDateComponentUndefined);
    XCTAssertEqual(saved.dueDateComponents.day, 3);
    XCTAssertEqual([self timeAlarms:saved].count, 0u);
    XCTAssertEqual(saved.startDateComponents.day, 3);

    NSDictionary *timed = [self createReminder:list options:@[@"--due", @"2027-02-03T18:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", timed);
    XCTAssertEqualObjects(timed[@"data"][@"is_all_day"], @NO);
    XCTAssertEqualObjects(timed[@"data"][@"notify"], @YES);
    XCTAssertEqualObjects(timed[@"data"][@"notify_at"], noff_format_date(noff_parse_date(@"2027-02-03T18:00:00")));
    saved = [self savedReminder:timed[@"data"][@"id"]];
    XCTAssertEqual(saved.dueDateComponents.hour, 18);
    XCTAssertEqual(saved.startDateComponents.hour, 18);
    XCTAssertEqual([self timeAlarms:saved].count, 1u);
    XCTAssertEqualObjects([self timeAlarms:saved].firstObject.absoluteDate, noff_parse_date(@"2027-02-03T18:00:00"));

    NSDictionary *relative = [self createReminder:list options:@[@"--due", @"-2h"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", relative);
    XCTAssertEqualObjects(relative[@"data"][@"notify"], @YES);
    XCTAssertEqual([self timeAlarms:[self savedReminder:relative[@"data"][@"id"]]].count, 1u);

    NSDictionary *off = [self createReminder:list options:@[@"--due", @"2027-02-03T18:00:00", @"--notify", @"off"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", off);
    XCTAssertEqualObjects(off[@"data"][@"notify"], @NO);
    XCTAssertEqual([self timeAlarms:[self savedReminder:off[@"data"][@"id"]]].count, 0u);

    NSDictionary *on = [self createReminder:list options:@[@"--due", @"2027-02-03", @"--notify", @"on"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", on);
    XCTAssertEqualObjects(on[@"data"][@"notify"], @YES);
    XCTAssertEqualObjects(on[@"data"][@"is_all_day"], @YES);

    // 经 apple-reminders 共用入口创建，行为一致。
    NSDictionary *shared = [self invokeReminderCommand:@"create" options:@[@"--title", @"Shared entry", @"--list", list,
        @"--due", @"2027-02-04T09:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", shared);
    XCTAssertEqualObjects(shared[@"data"][@"notify"], @YES);

    // list 返回 is_all_day，全天的 due 是 YYYY-MM-DD。
    NSDictionary *listed = [self invokeCommand:@"reminders" options:@[@"--list", list] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", listed);
    for (NSDictionary *item in listed[@"data"][@"reminders"]) {
        if ([item[@"id"] isEqualToString:dateOnly[@"data"][@"id"]]) {
            XCTAssertEqualObjects(item[@"is_all_day"], @YES);
            XCTAssertEqualObjects(item[@"due"], @"2027-02-03");
        }
        if ([item[@"id"] isEqualToString:timed[@"data"][@"id"]]) {
            XCTAssertEqualObjects(item[@"is_all_day"], @NO);
            XCTAssertEqualObjects(item[@"due"], noff_format_date(noff_parse_date(@"2027-02-03T18:00:00")));
        }
    }
    XCTAssertEqual([self remindersInTestList].count, 6u);
}

// R2：--notify on 缺少截止时间、取值无效都是 invalid_args，且不保存。
- (void)testReminderInvalidNotifyDoesNotSave {
    NSString *list = [self createReminderTestList];
    NSArray *cases = @[@[@"--notify", @"on"], @[@"--notify", @"maybe"],
                       @[@"--due", @"2027-02-03T18:00:00", @"--notify", @"maybe"], @[@"--due", @"2027-02-03", @"--notify"]];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self createReminder:list options:options exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ returned %@", options, json);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self remindersInTestList].count, 0u);
}

// R3、R4、R5：update 中通知随截止移动或移除；位置提醒保留；开始时间同步。
- (void)testReminderUpdateMovesAndRemovesNotification {
    NSString *list = [self createReminderTestList];
    int status;
    NSDictionary *created = [self createReminder:list options:@[@"--due", @"2027-02-03T18:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", created);
    NSString *identifier = created[@"data"][@"id"];

    // 用 EventKit 直接补一个位置提醒，验证通知规则不会动它。
    EKReminder *seed = [self savedReminder:identifier];
    EKStructuredLocation *place = [EKStructuredLocation locationWithTitle:@"Test place"];
    place.geoLocation = [[CLLocation alloc] initWithLatitude:22.5 longitude:114.0];
    place.radius = 200;
    EKAlarm *geofence = [[EKAlarm alloc] init];
    geofence.structuredLocation = place;
    geofence.proximity = EKAlarmProximityEnter;
    [seed addAlarm:geofence];
    NSError *error = nil;
    XCTAssertTrue([self.store saveReminder:seed commit:YES error:&error], @"%@", error);

    // 只改时刻：通知移到新时间，位置提醒仍在，开始时间同步。
    NSDictionary *moved = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--due", @"2027-02-05T07:30:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", moved);
    XCTAssertEqualObjects(moved[@"data"][@"notify"], @YES);
    XCTAssertEqualObjects(moved[@"data"][@"is_all_day"], @NO);
    EKReminder *saved = [self savedReminder:identifier];
    XCTAssertEqual([self timeAlarms:saved].count, 1u);
    XCTAssertEqualObjects([self timeAlarms:saved].firstObject.absoluteDate, noff_parse_date(@"2027-02-05T07:30:00"));
    XCTAssertEqual(saved.alarms.count, 2u);
    XCTAssertEqual(saved.startDateComponents.day, 5);
    XCTAssertEqual(saved.startDateComponents.hour, 7);

    // 改成纯日期：去掉时间通知，位置提醒保留，变为全天。
    NSDictionary *dateOnly = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--due", @"2027-02-06"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", dateOnly);
    XCTAssertEqualObjects(dateOnly[@"data"][@"notify"], @NO);
    XCTAssertEqualObjects(dateOnly[@"data"][@"is_all_day"], @YES);
    XCTAssertEqualObjects(dateOnly[@"data"][@"due"], @"2027-02-06");
    saved = [self savedReminder:identifier];
    XCTAssertEqual([self timeAlarms:saved].count, 0u);
    XCTAssertEqual(saved.alarms.count, 1u);
    XCTAssertNotNil(saved.alarms.firstObject.structuredLocation);
    XCTAssertEqual(saved.startDateComponents.day, 6);

    // 改回带时刻：原来没有通知，按创建时的默认加上。
    NSDictionary *timedAgain = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--due", @"2027-02-07T08:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", timedAgain);
    XCTAssertEqualObjects(timedAgain[@"data"][@"notify"], @YES);

    // --notify off 去掉时间通知；--notify on 在当前截止时间加回来。
    NSDictionary *silent = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--notify", @"off"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", silent);
    XCTAssertEqualObjects(silent[@"data"][@"notify"], @NO);
    saved = [self savedReminder:identifier];
    XCTAssertEqual([self timeAlarms:saved].count, 0u);
    XCTAssertEqual(saved.alarms.count, 1u);
    NSDictionary *loud = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--notify", @"on"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", loud);
    XCTAssertEqualObjects(loud[@"data"][@"notify"], @YES);
    saved = [self savedReminder:identifier];
    XCTAssertEqualObjects([self timeAlarms:saved].firstObject.absoluteDate, noff_parse_date(@"2027-02-07T08:00:00"));

    // 改成纯日期并同时 --notify on：保留一个通知。
    NSDictionary *kept = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--due", @"2027-02-08", @"--notify", @"on"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", kept);
    XCTAssertEqualObjects(kept[@"data"][@"notify"], @YES);

    // 无效取值：invalid_args，提醒不变。
    NSDictionary *bad = [self invokeCommand:@"update-reminder" options:@[@"--id", identifier, @"--title", @"Bad", @"--notify", @"maybe"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", bad);
    XCTAssertNotEqualObjects([self savedReminder:identifier].title, @"Bad");

    // 没有截止时间时 --notify on 被拒绝。
    NSDictionary *noDue = [self createReminder:list options:@[] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", noDue);
    NSDictionary *rejected = [self invokeCommand:@"update-reminder" options:@[@"--id", noDue[@"data"][@"id"], @"--notify", @"on"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", rejected);
}

// M1、B5：写入目标按名称完全一致匹配（忽略大小写）；子串、不存在的名称返回 invalid_args 并列出候选。
- (void)testExactCalendarAndListNameMatching {
    NSString *title = self.testCalendar.title;
    NSString *prefix = [title substringToIndex:title.length - 6];
    NSArray *window = @[@"--start", @"2027-06-01T09:00:00", @"--end", @"2027-06-01T10:00:00"];
    int status;
    NSDictionary *partial = [self invoke:[@[@"--title", @"Partial", @"--calendar", prefix] arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", partial);
    XCTAssertEqualObjects(partial[@"error"][@"code"], @"invalid_args");
    XCTAssertTrue([partial[@"error"][@"message"] containsString:title], @"%@", partial);
    XCTAssertEqual([self eventCountInTestCalendar], 0u);

    NSDictionary *upper = [self invoke:[@[@"--title", @"Upper", @"--calendar", title.uppercaseString] arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", upper);
    XCTAssertEqualObjects(upper[@"data"][@"calendar"], title);

    // update 名称不符：invalid_args，事件保持原日历和原标题。
    NSDictionary *moved = [self invokeCommand:@"update" options:@[@"--id", upper[@"data"][@"id"], @"--title", @"Changed", @"--calendar", prefix] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", moved);
    XCTAssertTrue([moved[@"error"][@"message"] containsString:title], @"%@", moved);
    EKEvent *saved = [self savedEvent:upper[@"data"][@"id"]];
    XCTAssertEqualObjects(saved.title, @"Upper");
    XCTAssertEqualObjects(saved.calendar.calendarIdentifier, self.calendarID);

    // 提醒清单：同样规则，且不写入默认清单。
    NSString *list = [self createReminderTestList];
    NSString *listPrefix = [list substringToIndex:list.length - 6];
    NSDictionary *reminder = [self createReminder:listPrefix options:@[] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", reminder);
    XCTAssertTrue([reminder[@"error"][@"message"] containsString:list], @"%@", reminder);
    XCTAssertEqual([self remindersInTestList].count, 0u);
    NSDictionary *created = [self createReminder:list.lowercaseString options:@[] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", created);
    XCTAssertEqualObjects(created[@"data"][@"list"], list);
    NSDictionary *badMove = [self invokeCommand:@"update-reminder" options:@[@"--id", created[@"data"][@"id"], @"--title", @"Changed", @"--list", listPrefix] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", badMove);
    XCTAssertTrue([badMove[@"error"][@"message"] containsString:list], @"%@", badMove);
    XCTAssertNotEqualObjects([self savedReminder:created[@"data"][@"id"]].title, @"Changed");
}

// M2：事件 create / update / delete 返回 calendar_id、calendar_source；提醒 create / update / complete / delete 返回 list_id、list_source。
- (void)testOwnershipFields {
    int status;
    NSString *source = self.testCalendar.source.title ?: @"";
    NSDictionary *created = [self createEvent:@[@"--start", @"2027-06-01T09:00:00", @"--end", @"2027-06-01T10:00:00"]];
    NSString *eventID = created[@"data"][@"id"];
    XCTAssertEqualObjects(created[@"data"][@"calendar_id"], self.calendarID);
    XCTAssertEqualObjects(created[@"data"][@"calendar_source"], source);
    NSDictionary *updated = [self invokeCommand:@"update" options:@[@"--id", eventID, @"--title", @"Owned"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", updated);
    XCTAssertEqualObjects(updated[@"data"][@"calendar_id"], self.calendarID);
    XCTAssertEqualObjects(updated[@"data"][@"calendar_source"], source);
    NSDictionary *deleted = [self invokeCommand:@"delete" options:@[@"--id", eventID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", deleted);
    XCTAssertEqualObjects(deleted[@"data"][@"calendar_id"], self.calendarID);
    XCTAssertEqualObjects(deleted[@"data"][@"calendar_source"], source);

    NSString *list = [self createReminderTestList];
    NSString *listSource = [self.store calendarWithIdentifier:self.reminderCalendarID].source.title ?: @"";
    NSDictionary *reminder = [self createReminder:list options:@[@"--due", @"2027-06-01"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", reminder);
    NSString *reminderID = reminder[@"data"][@"id"];
    XCTAssertEqualObjects(reminder[@"data"][@"list_id"], self.reminderCalendarID);
    XCTAssertEqualObjects(reminder[@"data"][@"list_source"], listSource);
    NSDictionary *reminderUpdate = [self invokeCommand:@"update-reminder" options:@[@"--id", reminderID, @"--title", @"Owned"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", reminderUpdate);
    XCTAssertEqualObjects(reminderUpdate[@"data"][@"list_id"], self.reminderCalendarID);
    XCTAssertEqualObjects(reminderUpdate[@"data"][@"list_source"], listSource);
    NSDictionary *completed = [self invokeCommand:@"complete-reminder" options:@[@"--id", reminderID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", completed);
    XCTAssertEqualObjects(completed[@"data"][@"list_id"], self.reminderCalendarID);
    XCTAssertEqualObjects(completed[@"data"][@"list_source"], listSource);
    NSDictionary *removed = [self invokeCommand:@"delete-reminder" options:@[@"--id", reminderID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", removed);
    XCTAssertEqualObjects(removed[@"data"][@"list_id"], self.reminderCalendarID);
    XCTAssertEqualObjects(removed[@"data"][@"list_source"], listSource);
}

// 创建与已有日历/清单同名、同来源的对象，测试结束时移除；等待产品读路径可见。
- (NSString *)createDuplicateOf:(NSString *)originalID {
    EKCalendar *original = [self.store calendarWithIdentifier:originalID];
    EKCalendar *copy = [EKCalendar calendarForEntityType:original.allowedEntityTypes & EKEntityMaskEvent ? EKEntityTypeEvent : EKEntityTypeReminder
                                              eventStore:self.store];
    copy.title = original.title;
    copy.source = original.source;
    NSError *error = nil;
    XCTAssertTrue([self.store saveCalendar:copy commit:YES error:&error], @"%@", error);
    NSString *copyID = copy.calendarIdentifier;
    [self addTeardownBlock:^{
        EKCalendar *leftover = [self.store calendarWithIdentifier:copyID];
        NSError *removeError = nil;
        if (leftover) XCTAssertTrue([self.store removeCalendar:leftover commit:YES error:&removeError], @"%@", removeError);
    }];
    XCTestExpectation *propagated = [self expectationWithDescription:@"duplicate propagation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [propagated fulfill]; });
    [self waitForExpectations:@[propagated] timeout:2];
    return copyID;
}

// M4：同名日历按名称报歧义（带来源和 ID），按 ID 写入正确的那个；名称与 ID 同时给出、未知 ID 都是 invalid_args。
- (void)testDuplicateCalendarNamesNeedId {
    NSString *title = self.testCalendar.title;
    NSString *dupID = [self createDuplicateOf:self.calendarID];
    NSArray *window = @[@"--start", @"2027-06-01T09:00:00", @"--end", @"2027-06-01T10:00:00"];
    int status;
    NSDictionary *ambiguous = [self invoke:[@[@"--title", @"Ambiguous", @"--calendar", title] arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", ambiguous);
    NSString *message = ambiguous[@"error"][@"message"];
    XCTAssertTrue([message containsString:self.calendarID] && [message containsString:dupID], @"%@", message);
    XCTAssertTrue([message containsString:self.testCalendar.source.title], @"%@", message);
    XCTAssertEqual([self eventCountInTestCalendar], 0u);

    NSDictionary *byID = [self invoke:[@[@"--title", @"ById", @"--calendar-id", dupID] arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", byID);
    XCTAssertEqualObjects(byID[@"data"][@"calendar_id"], dupID);
    XCTAssertEqualObjects([self savedEvent:byID[@"data"][@"id"]].calendar.calendarIdentifier, dupID);

    // update：歧义和错误组合都不改动事件，按 ID 移回原日历。
    NSString *identifier = byID[@"data"][@"id"];
    NSDictionary *badMove = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed", @"--calendar", title] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", badMove);
    NSDictionary *both = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed", @"--calendar", title,
        @"--calendar-id", self.calendarID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", both);
    NSDictionary *unknown = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed",
        @"--calendar-id", NSUUID.UUID.UUIDString] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", unknown);
    XCTAssertTrue([unknown[@"error"][@"message"] containsString:dupID], @"%@", unknown);
    XCTAssertEqualObjects([self savedEvent:identifier].title, @"ById");
    NSDictionary *moved = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--calendar-id", self.calendarID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", moved);
    XCTAssertEqualObjects(moved[@"data"][@"calendar_id"], self.calendarID);

    NSDictionary *createBoth = [self invoke:[@[@"--title", @"Both", @"--calendar", title, @"--calendar-id", self.calendarID]
        arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", createBoth);
    NSDictionary *createUnknown = [self invoke:[@[@"--title", @"Unknown", @"--calendar-id", NSUUID.UUID.UUIDString]
        arrayByAddingObjectsFromArray:window] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", createUnknown);
    XCTAssertEqual([self eventCountInTestCalendar], 1u);
}

// M4：同名提醒清单同样需要 --list-id；apple-reminders 共用入口行为一致。
- (void)testDuplicateListNamesNeedId {
    NSString *list = [self createReminderTestList];
    NSString *dupID = [self createDuplicateOf:self.reminderCalendarID];
    int status;
    NSDictionary *ambiguous = [self createReminder:list options:@[] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", ambiguous);
    NSString *message = ambiguous[@"error"][@"message"];
    XCTAssertTrue([message containsString:self.reminderCalendarID] && [message containsString:dupID], @"%@", message);
    XCTAssertEqual([self remindersInTestList].count, 0u);

    NSDictionary *byID = [self invokeReminderCommand:@"create" options:@[@"--title", @"ById", @"--list-id", dupID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", byID);
    XCTAssertEqualObjects(byID[@"data"][@"list_id"], dupID);
    NSString *identifier = byID[@"data"][@"id"];

    NSDictionary *badMove = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed", @"--list", list] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", badMove);
    NSDictionary *both = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed", @"--list", list,
        @"--list-id", self.reminderCalendarID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", both);
    NSDictionary *unknown = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--title", @"Changed",
        @"--list-id", NSUUID.UUID.UUIDString] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@", unknown);
    XCTAssertNotEqualObjects([self savedReminder:identifier].title, @"Changed");
    NSDictionary *moved = [self invokeReminderCommand:@"update" options:@[@"--id", identifier, @"--list-id", self.reminderCalendarID] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", moved);
    XCTAssertEqualObjects(moved[@"data"][@"list_id"], self.reminderCalendarID);
    XCTAssertEqual([self remindersInTestList].count, 1u);
}

// D8：全天事件只给带时刻的 --start，结束为当天 22:00；22:00 及以后为开始后 1 小时（含跨午夜）。
- (void)testAllDayToTimedWithOnlyStart {
    NSArray *cases = @[@[@"2027-08-02T14:00:00", @"2027-08-02T22:00:00"],
                       @[@"2027-08-02T22:00:00", @"2027-08-02T23:00:00"],
                       @[@"2027-08-02T22:30:00", @"2027-08-02T23:30:00"],
                       @[@"2027-08-02T23:30:00", @"2027-08-03T00:30:00"]];
    for (NSArray *c in cases) {
        NSDictionary *created = [self createEvent:@[@"--start", @"2027-08-02", @"--end", @"2027-08-02"]];
        int status;
        NSDictionary *updated = [self invokeCommand:@"update" options:@[@"--id", created[@"data"][@"id"], @"--start", c[0]] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@ %@", c, updated);
        XCTAssertEqualObjects(updated[@"data"][@"is_all_day"], @NO);
        EKEvent *saved = [self savedEvent:created[@"data"][@"id"]];
        XCTAssertFalse(saved.isAllDay);
        XCTAssertEqualObjects(saved.startDate, noff_parse_date(c[0]), @"%@", c);
        XCTAssertEqualObjects(saved.endDate, noff_parse_date(c[1]), @"%@", c);
    }
}

// D8：只给 --end，或一端带时刻另一端纯日期：invalid_args，事件保持全天不变；两端都带时刻照常写入。
- (void)testAllDayToTimedRejectsAmbiguousArguments {
    NSDictionary *created = [self createEvent:@[@"--start", @"2027-08-02", @"--end", @"2027-08-02"]];
    NSString *identifier = created[@"data"][@"id"];
    NSArray *cases = @[@[@"--end", @"2027-08-02T15:00:00"],
                       @[@"--start", @"2027-08-02T14:00:00", @"--end", @"2027-08-02"],
                       @[@"--start", @"2027-08-02", @"--end", @"2027-08-02T15:00:00"]];
    for (NSArray *options in cases) {
        int status;
        NSDictionary *json = [self invokeCommand:@"update" options:[@[@"--id", identifier, @"--title", @"Changed"] arrayByAddingObjectsFromArray:options] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS, @"%@ %@", options, json);
        EKEvent *saved = [self savedEvent:identifier];
        XCTAssertTrue(saved.isAllDay, @"%@", options);
        XCTAssertNotEqualObjects(saved.title, @"Changed");
        XCTAssertEqualObjects(saved.startDate, [self localDay:@"2027-08-02"]);
        XCTAssertEqualObjects(saved.endDate, [self localEndOfDay:@"2027-08-02"]);
    }
    int status;
    NSDictionary *both = [self invokeCommand:@"update" options:@[@"--id", identifier, @"--start", @"2027-08-02T14:00:00",
        @"--end", @"2027-08-02T15:00:00"] exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_SUCCESS, @"%@", both);
    EKEvent *saved = [self savedEvent:identifier];
    XCTAssertFalse(saved.isAllDay);
    XCTAssertEqualObjects(saved.endDate, noff_parse_date(@"2027-08-02T15:00:00"));
}

// 辅助函数 noff_is_date_only_string / noff_all_day_bounds 的边界。
- (void)testAllDayHelpers {
    XCTAssertTrue(noff_is_date_only_string(@"2027-12-01"));
    XCTAssertFalse(noff_is_date_only_string(@"2027-12-01T09:00"));
    XCTAssertFalse(noff_is_date_only_string(@"2027-13-01"));
    XCTAssertFalse(noff_is_date_only_string(@"2027/12/01"));
    XCTAssertFalse(noff_is_date_only_string(@"-2h"));
    XCTAssertFalse(noff_is_date_only_string(nil));
    NSDate *start, *end;
    noff_all_day_bounds(noff_parse_date(@"2027-12-01T14:00:00"), noff_parse_date(@"2027-12-03T01:00:00"), &start, &end);
    XCTAssertEqualObjects(start, [self localDay:@"2027-12-01"]);
    XCTAssertEqualObjects(end, [self localEndOfDay:@"2027-12-03"]);
}
@end
