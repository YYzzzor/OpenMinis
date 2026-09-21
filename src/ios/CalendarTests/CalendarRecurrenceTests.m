#import <XCTest/XCTest.h>
#import <EventKit/EventKit.h>
#import "CalendarOffload.h"
#import "NativeOffloadUtils.h"

// 通过产品命令真实保存到独立模拟器日历，再用另一个 store 读取实际发生日期。
// 每个测试只删除自己创建的唯一日历，不读取或修改用户日历事件。
@interface CalendarRecurrenceTests : XCTestCase
@property (nonatomic, strong) EKEventStore *store;
@property (nonatomic, strong) EKCalendar *testCalendar;
@property (nonatomic, copy) NSString *calendarID;
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
    EKSource *source = nil;
    for (EKSource *candidate in self.store.sources) {
        if (candidate.sourceType == EKSourceTypeLocal) { source = candidate; break; }
    }
    XCTAssertNotNil(source, @"Tests require a simulator local calendar source.");
    self.testCalendar = [EKCalendar calendarForEntityType:EKEntityTypeEvent eventStore:self.store];
    self.testCalendar.title = [@"MinisX-Recurrence-Test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    self.testCalendar.source = source;
    NSError *error = nil;
    XCTAssertTrue([self.store saveCalendar:self.testCalendar commit:YES error:&error], @"%@", error);
    self.calendarID = self.testCalendar.calendarIdentifier;
    XCTestExpectation *propagated = [self expectationWithDescription:@"calendar change propagation"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [propagated fulfill]; });
    [self waitForExpectations:@[propagated] timeout:2];
}

- (void)tearDown {
    if (self.calendarID) {
        NSError *error = nil;
        XCTAssertTrue([self.store removeCalendar:[self.store calendarWithIdentifier:self.calendarID] commit:YES error:&error], @"%@", error);
    }
    self.testCalendar = nil;
    self.store = nil;
    [super tearDown];
}

- (NSDictionary *)invoke:(NSArray<NSString *> *)options exit:(int *)exitCode {
    return [self invokeCommand:@"create" options:options exit:exitCode];
}

- (NSDictionary *)invokeCommand:(NSString *)command options:(NSArray<NSString *> *)options exit:(int *)exitCode {
    NSArray *args = [@[@"apple-calendar", command] arrayByAddingObjectsFromArray:options];
    XCTestExpectation *finished = [self expectationWithDescription:@"native create"];
    __block NSDictionary *json;
    __block int status;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char **argv = calloc(args.count, sizeof(char *));
        for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup([args[i] UTF8String]);
        FILE *output = tmpfile();
        FILE *errors = tmpfile();
        status = calendar_offload_handle((int)args.count, argv, -1, fileno(output), fileno(errors));
        lseek(fileno(output), 0, SEEK_SET);
        NSData *bytes = [[[NSFileHandle alloc] initWithFileDescriptor:fileno(output) closeOnDealloc:NO] readDataToEndOfFile];
        json = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL];
        fclose(output);
        fclose(errors);
        for (NSUInteger i = 0; i < args.count; i++) free(argv[i]);
        free(argv);
        [finished fulfill];
    });
    [self waitForExpectations:@[finished] timeout:40];
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
        if (countIndex != NSNotFound) {
            XCTAssertEqual(rule.recurrenceEnd.occurrenceCount, [options[countIndex + 1] integerValue]);
            XCTAssertEqualObjects(reported[@"end"][@"type"], @"count");
        } else if ([options containsObject:@"--recurrence-until"]) {
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
        @"--start", @"--end", @"--recurrence", @"--help", @"--compact", @"--quiet"];
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

- (void)testUnknownCalendarDoesNotFallBack {
    NSArray *options = @[@"--title", @"Must not save", @"--calendar", NSUUID.UUID.UUIDString,
        @"--start", @"2027-01-01T09:00:00Z", @"--end", @"2027-01-01T10:00:00Z",
        @"--recurrence", @"weekly"];
    int status;
    NSDictionary *json = [self invoke:options exit:&status];
    XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS);
    XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
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

- (void)testNonCreateRejectsRecurrenceOptions {
    for (NSString *command in @[@"list", @"update", @"remind"]) {
        int status;
        NSDictionary *json = [self invokeCommand:command options:@[@"--recurrence", @"weekly"] exit:&status];
        XCTAssertEqual(status, NOFF_EXIT_INVALID_ARGS);
        XCTAssertEqualObjects(json[@"error"][@"code"], @"invalid_args");
    }
    XCTAssertEqual([self eventsFrom:@"2027-01-01T00:00:00Z" to:@"2028-01-01T00:00:00Z"].count, 0u);
}
@end
