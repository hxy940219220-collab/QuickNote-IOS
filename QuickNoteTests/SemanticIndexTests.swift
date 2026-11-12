import Combine
import Foundation
import XCTest
@testable import QuickNote

@MainActor
final class SemanticIndexTests: XCTestCase {
    private static let workerLeaseQuestion = "同一个 job 换了 worker 后，怎么阻止 lease 已过期的前一个 worker 把旧结果提交到数据库？"

    func testWorkerLeaseRetainsKeywordEvidenceInHybridTopSix() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = Self.stageACorpus.enumerated().map { offset, note in
            NoteIndexSnapshot(noteID: Self.noteID(offset + 1), title: note.0, text: note.1, revision: 1)
        }
        let question = Self.workerLeaseQuestion
        // Frozen top-six cosine similarities from A, whose vector search missed N04.
        let priorTop: [Int: Float] = [8: 0.83708, 1: 0.82417, 19: 0.82172, 15: 0.81663, 9: 0.79680, 25: 0.78892]
        let similarities = Dictionary(uniqueKeysWithValues: notes.enumerated().map {
            ($0.element.text, priorTop[$0.offset + 1] ?? 0.7)
        })
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "stage-a", revision: 1, dimension: 2), vector: { text in
                if text == question { return [1, 0] }
                let cosine = similarities[text, default: 0.7]
                return [cosine, sqrt(1 - cosine * cosine)]
            })
        })
        index.replaceLibrary(with: notes)
        let result = await index.search(question)
        XCTAssertEqual(result.mode, .hybrid)
        XCTAssertEqual(result.hits.count, 6)
        let evidence = try XCTUnwrap(result.hits.first { $0.chunk.noteID == Self.noteID(4) })
        XCTAssertTrue(evidence.chunk.text.contains("fencing token"))
        XCTAssertGreaterThan(evidence.keywordScore, 0)
        XCTAssertTrue(result.hits.allSatisfy { (0...1).contains($0.score) && (0...1).contains($0.keywordScore) })
    }

    func testExactLatinKeywordSurvivesCrowdingBySimilarPartialWords() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exact = snapshot(text: "worker 的 lease 过期了", revision: 1)
        let related = (0..<8).map { snapshot(text: "leaseholder related \($0)", revision: 1) }
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "test", revision: 1, dimension: 2), vector: { text in
                text.contains("过期") ? [-1, 0] : [1, 0]
            })
        })
        index.replaceLibrary(with: related + [exact])
        let result = await index.search("LEASE")
        let exactHit = try XCTUnwrap(result.hits.first { $0.chunk.noteID == exact.noteID })
        XCTAssertEqual(exactHit.keywordScore, 1)
        XCTAssertEqual(exactHit.cosineSimilarity, -1)
        XCTAssertTrue(result.hits.filter { $0.chunk.noteID != exact.noteID }.allSatisfy { $0.keywordScore == 0 })
    }

    func testMissingAssetsFallsBackToBM25AndRemovesOldVectors() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = snapshot(text: "索引使用 BM25", revision: 2)
        let first = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        first.replaceLibrary(with: [note])
        await first.flushPending()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(note.noteID, directory).path))

        let fallback = SemanticIndex(directory: directory, embedding: { nil })
        fallback.replaceLibrary(with: [note])
        let result = await fallback.search("bm25")
        XCTAssertEqual(result.mode, .keyword)
        XCTAssertEqual(result.mode.notice, "当前为关键词检索")
        XCTAssertEqual(result.hits.map(\.chunk.noteID), [note.noteID])
        XCTAssertEqual(result.hits.map(\.score), [1])
        XCTAssertNil(result.hits.first?.cosineSimilarity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(note.noteID, directory).path))
    }

    func testMatchingCacheReusesVectorsButKeepsCurrentRevisionAndTitle() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = snapshot(text: "稀有标题关键词", revision: 1)
        let first = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        first.replaceLibrary(with: [note])
        await first.flushPending()

        let probe = WorkProbe()
        let current = NoteIndexSnapshot(noteID: note.noteID, title: "当前标题", text: note.text, revision: 8)
        let second = SemanticIndex(directory: directory, embedding: { Self.embedding(probe: probe) })
        second.replaceLibrary(with: [current])
        await second.flushPending()
        XCTAssertEqual(probe.calls, 0, "同一模型和正文应复用磁盘向量")
        let result = await second.search("关键词")
        XCTAssertEqual(result.hits.first?.chunk.revision, 8)
        XCTAssertEqual(result.hits.first?.chunk.title, "当前标题")
    }

    func testCacheRebuildsForModelIdentifierRevisionAndSourceChanges() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = snapshot(text: "初始文字", revision: 1)
        let first = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        first.replaceLibrary(with: [note])
        await first.flushPending()

        for (identifier, revision, text) in [("other", 1, note.text), ("other", 2, note.text), ("other", 2, "改写后的文字")] {
            let probe = WorkProbe()
            let replacement = SemanticIndex(directory: directory, embedding: {
                Self.embedding(identifier: identifier, revision: revision, probe: probe)
            })
            let changed = NoteIndexSnapshot(noteID: note.noteID, title: note.title, text: text, revision: 1)
            replacement.replaceLibrary(with: [changed])
            await replacement.flushPending()
            XCTAssertEqual(probe.calls, 1, "不同模型、模型版本或正文必须重建向量")
            let data = try Data(contentsOf: cacheURL(note.noteID, directory))
            let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let model = try XCTUnwrap(cache["model"] as? [String: Any])
            XCTAssertEqual(model["identifier"] as? String, identifier)
            XCTAssertEqual(model["revision"] as? Int, revision)
        }
    }

    func testRemovePurgesCacheSynchronouslyAndCancelsDebouncedSaveThenRestores() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        let note = snapshot(text: "原始内容", revision: 1)
        index.replaceLibrary(with: [note])
        await index.flushPending()
        let file = cacheURL(note.noteID, directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let update = NoteIndexSnapshot(noteID: note.noteID, title: note.title, text: "更新内容", revision: 2)
        try index.apply(.saved(update))
        try index.apply(.removed(note.noteID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await index.flushPending()
        let removed = await index.search("更新")
        XCTAssertTrue(removed.hits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try index.apply(.saved(update), immediately: true)
        let restored = await index.search("更新")
        XCTAssertEqual(restored.hits.first?.chunk.revision, 2)
        XCTAssertEqual(restored.hits.first?.chunk.text, "更新内容")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testDebounceCoalescesEditsAndUsesTheLatestRevision() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = WorkProbe()
        let index = SemanticIndex(directory: directory, debounce: .seconds(60), embedding: { Self.embedding(probe: probe) })
        let id = UUID()
        for revision in 1...3 {
            try index.apply(.saved(.init(noteID: id, title: "便签", text: "编辑内容 \(revision)", revision: revision)))
        }
        XCTAssertEqual(probe.calls, 0)
        await index.flushPending()
        XCTAssertEqual(probe.calls, 1)
        let result = await index.search("编辑")
        XCTAssertEqual(result.hits.first?.chunk.revision, 3)
    }

    func testLateEmbeddingCannotCommitAfterRemoval() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latch = WorkLatch()
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "latch", revision: 1, dimension: 2), vector: { text in
                if text == "等待中的正文" { latch.pause() }
                return [1, 0]
            })
        })
        let note = snapshot(text: "等待中的正文", revision: 1)
        index.replaceLibrary(with: [note])
        let started = await latch.waitForStart()
        XCTAssertTrue(started)
        do {
            try index.apply(.removed(note.noteID))
        } catch {
            latch.resume()
            throw error
        }
        latch.resume()
        await index.flushPending()
        let result = await index.search("正文")
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(note.noteID, directory).path))
    }

    func testInFlightSearchExcludesAChunkRemovedBeforeItReturns() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latch = WorkLatch()
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "latch", revision: 1, dimension: 2), vector: { text in
                if text == "等待中的查询" { latch.pause() }
                return [1, 0]
            })
        })
        let note = snapshot(text: "等待中的查询所需内容", revision: 1)
        index.replaceLibrary(with: [note])
        await index.flushPending()
        let search = Task { await index.search("等待中的查询") }
        let started = await latch.waitForStart()
        XCTAssertTrue(started)
        do {
            try index.apply(.removed(note.noteID))
        } catch {
            latch.resume()
            throw error
        }
        latch.resume()
        let result = await search.value
        XCTAssertTrue(result.hits.isEmpty)
    }

    func testStartupPurgesCachedNotesAbsentFromEligibleSnapshots() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = snapshot(text: "允许正文", revision: 1)
        let omitted = snapshot(text: "不再合格", revision: 1)
        let first = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        first.replaceLibrary(with: [note, omitted])
        await first.flushPending()
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL(omitted.noteID, directory).path))

        let reopened = SemanticIndex(directory: directory, embedding: { Self.embedding() })
        reopened.replaceLibrary(with: [note])
        let result = await reopened.search("合格")
        XCTAssertFalse(result.hits.contains { $0.chunk.noteID == omitted.noteID })
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(omitted.noteID, directory).path))
    }

    func testAvailableSearchUsesPublishedKeywordsWhileEmbeddingsAreBlocked() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latch = WorkLatch()
        defer { latch.resume() }
        let note = snapshot(text: "封面手稿保存在蓝色档案夹", revision: 1)
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "latch", revision: 1, dimension: 2), vector: { text in
                if text == note.text { latch.pause() }
                return [1, 0]
            })
        })
        index.beginLibraryLoad()
        XCTAssertTrue(index.isBuilding)
        let beforeSnapshots = await index.searchAvailable("手稿")
        XCTAssertEqual(beforeSnapshots.mode, .keyword)
        XCTAssertTrue(beforeSnapshots.hits.isEmpty)

        index.replaceLibrary(with: [note])
        let started = await latch.waitForStart()
        XCTAssertTrue(started)
        let partial = await index.searchAvailable("手稿")
        XCTAssertEqual(partial.mode, .keyword)
        XCTAssertEqual(partial.hits.map(\.chunk.noteID), [note.noteID])
        XCTAssertTrue(index.isBuilding)

        try index.apply(.removed(note.noteID))
        let removed = await index.searchAvailable("手稿")
        XCTAssertTrue(removed.hits.isEmpty)
        latch.resume()
        await index.flushPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL(note.noteID, directory).path))
    }

    func testSupersededBuildKeepsNewLibraryKeywordsAndDoesNotPublishOldReadiness() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = WorkLatch()
        let second = WorkLatch()
        defer {
            first.resume()
            second.resume()
        }
        let old = snapshot(text: "过期手稿", revision: 1)
        let replacement = snapshot(text: "当前手稿", revision: 2)
        let index = SemanticIndex(directory: directory, embedding: {
            .init(model: .init(identifier: "latch", revision: 1, dimension: 2), vector: { text in
                if text == old.text { first.pause() }
                if text == replacement.text { second.pause() }
                return [1, 0]
            })
        })

        index.replaceLibrary(with: [old])
        let firstStarted = await first.waitForStart()
        XCTAssertTrue(firstStarted)
        index.beginLibraryLoad()
        index.replaceLibrary(with: [replacement])
        first.resume()

        let secondStarted = await second.waitForStart()
        XCTAssertTrue(secondStarted)
        let partial = await index.searchAvailable("手稿")
        XCTAssertEqual(partial.mode, .keyword)
        XCTAssertEqual(partial.hits.map(\.chunk.noteID), [replacement.noteID])
        XCTAssertTrue(index.isBuilding)
        let ready = expectation(description: "当前索引构建完成后发布就绪状态")
        let subscription = index.$isBuilding.filter { !$0 }.prefix(1).sink { _ in ready.fulfill() }
        second.resume()
        let readiness = await XCTWaiter.fulfillment(of: [ready], timeout: 2)
        withExtendedLifetime(subscription) {}
        XCTAssertEqual(readiness, .completed)
        let result = await index.searchAvailable("手稿")
        XCTAssertEqual(result.mode, .hybrid)
        XCTAssertEqual(result.hits.map(\.chunk.noteID), [replacement.noteID])
    }

    func testThousandNoteBuildAndQueryRunOffMainWithInjectedVectors() async throws {
        try await runThousandNoteBenchmark(label: "injected") { probe in Self.embedding(probe: probe) }
    }

    func testThousandNoteBuildAndQueryWithLocalChineseAssets() async throws {
        try await runThousandNoteBenchmark(label: "localChinese") { probe in
            guard let local = NoteIndexEmbedding.localChinese() else { return nil }
            return .init(model: local.model, vector: { text in
                probe.record()
                return local.vector(text)
            })
        }
    }

    private func runThousandNoteBenchmark(label: String,
        embedding: @escaping @Sendable (WorkProbe) -> NoteIndexEmbedding?) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let notes = (1...1_000).map { number in
            let topic = ["喷泉", "管线", "冷藏", "装运"][number % 4]
            return NoteIndexSnapshot(noteID: Self.noteID(number), title: "合成记录 \(number)",
                text: "第 \(number) 项\(topic)设备验收。检查接口固定、现场温度和备件清单。", revision: 1)
        }
        let probe = WorkProbe()
        let clock = ContinuousClock()
        let buildStart = clock.now
        let index = SemanticIndex(directory: directory, embedding: {
            let provider = embedding(probe)
            probe.recordLoad(available: provider != nil)
            return provider
        })
        index.replaceLibrary(with: notes)
        await index.flushPending()
        let build = buildStart.duration(to: clock.now)
        try XCTSkipUnless(probe.modelAvailable, "本机中文上下文模型资产不可用")
        XCTAssertEqual(probe.calls, 1_000)
        XCTAssertFalse(probe.usedMainThread)
        let queryStart = clock.now
        let result = await index.search("管线设备的备件清单")
        let query = queryStart.duration(to: clock.now)
        XCTAssertEqual(result.mode, .hybrid)
        XCTAssertEqual(result.hits.count, 6)
        XCTAssertFalse(probe.usedMainThread)
        XCTAssertLessThan(query, .milliseconds(200))
        print("Task07B benchmark \(label) notes=1000 build=\(build) query=\(query)")
    }

    private nonisolated static func embedding(identifier: String = "test", revision: Int = 1,
                                              probe: WorkProbe? = nil) -> NoteIndexEmbedding {
        .init(model: .init(identifier: identifier, revision: revision, dimension: 2), vector: { _ in
            probe?.record()
            return [1, 0]
        })
    }

    private static func noteID(_ number: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", number))")!
    }

    private func snapshot(text: String, revision: Int) -> NoteIndexSnapshot {
        .init(noteID: UUID(), title: "便签", text: text, revision: revision)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickNoteIndex-\(UUID())", isDirectory: true)
    }

    private func cacheURL(_ id: UUID, _ directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString + ".qni")
    }

    // Exact synthetic corpus used for the A-phase worker-lease question. IDs are implicit 1...30.
    private static let stageACorpus: [(String, String)] = [
        ("Safari mp4 跳转压测", "Safari 里拖动 mp4 的进度条时，网络面板会产生多个 range 请求。用 FFmpeg 的压测脚本统计每个分段加载耗时，保留公网和内网两个结果。"),
        ("苗圃体验课应急位置", "如果院子太湿，栽花环节迁到教学楼一层的陶艺教室。盆和土由教员搬过去，学员依照当天通知到场。"),
        ("关闭面板的断言方式", "测试 focus 和可见性时等待面板状态进入 closed 再断言。动效可以由测试时钟推进，避免用固定毫秒的 sleep 猜测 transition 是否结束。"),
        ("队列任务的提交约束", "任务每次换人接手都会拿到更大的 fencing token。落库 UPDATE 带当前令牌的条件，租约已经转交时前任手里的旧值匹配不到记录，提交便作废。"),
        ("朗读访谈的室内布置", "空会议室录出的对话尾音拖得太长。把折叠桌移到有帘子的墙边，在收音设备背后挂厚毯，椅脚也铺一张布，随后重录十秒对比。"),
        ("版画课退款窗口", "版画体验课因主办方取消时全额退款。助教在晚上八点后集中核对原付款记录，报名群里的日常问答不视作退款申请。"),
        ("水性颜料色卡记录", "上釉用的水性颜料结块后不加入新料。调色台要及时擦净，水槽边的样品记录用于判断晾干后是否变浅，与冬季仓储分开登记。"),
        ("午夜 job 日志看板", "午夜 job 在 worker 切换时重复输出开始事件。告警面板把相同 job_id 的日志折叠；lease 过期仍单独计数，以便查到机器忙碌导致的处理延迟。"),
        ("macOS Reduce Motion 观察", "Reduce Motion 开关打开后，面板 snapshot 录制中能看到更少的中间帧。排查画面闪动时把系统开关一并记到 CI 的视频附件说明。"),
        ("栽花班当天联络", "碰到阴雨，领队当天七点半在报名群发布是否从院子搬进屋里的通知。没有通知前按原定集合点走。"),
        ("GeoJSON 地图图块缺失", "地图 import 后，近海的注记层有时消失。排查 tile 服务的 y 原点是否为左下角，同时确认缩放级别能请求到该层；这个问题只影响背景图块。"),
        ("坐标导入时的数组顺序", "GeoJSON 的第一个数字对应 longitude，第二个对应 latitude。导入器收到来源表的纬经顺序时要按此约定重排，另检查经纬度是否落在合理区间。"),
        ("测试环境签名轮换演练", "测试网关的 signing key 更换演练周三进行。观察旧客户端验签失败率和日志回滚时间，演练只涉及网关签出的测试令牌，接收订单通知的服务不参与。"),
        ("分享嘉宾铁路报账", "外地讲者的车票在论坛结束后三天内交。列车晚点通知可以随票附上，报账联系人是小满，只核对实际抵达时间和购票金额。"),
        ("收件服务的幂等凭据", "订单事件投递方会把同一个 event_id 再发数次。消费方先把这个编号写入 inbox 表，依靠唯一约束拦掉已处理的事件。HTTP 连接的编号只用于排查。"),
        ("本机检索引擎缺模型时", "本机 token 字典包没有落盘时，保留关键词检索的候选并提示本地模型不可用。已经选择仅在设备上处理的用户，界面停在这个结果页。"),
        ("楼顶导览雨天安排", "楼顶的观景导览下雨就暂停，负责签到的人八点到大厅口给参与者说明。与一层的手作课程各自安排。"),
        ("旧书交换志愿者站位", "周六旧书交换开始前，志愿者先在柳枝礼堂东门集合领围裙。东门台阶边摆桌，只放工作人员的物资。大厅登记台核对的是带来的书本数量。"),
        ("Webhook retry 排错", "Webhook retry 时每次 request_id 都不同。排错时把这个编号写进 access log 以区分请求，并记录响应状态与 backoff。接收端验签失败会返回 401。"),
        ("露台访谈录音检查", "户外采访遇到大风时给话筒套毛绒防风罩，受访者站在挡风板侧边。设备的增益维持原档，减少现场反复调试。"),
        ("Offline mode 下载提示", "离线 mode 会暂停 tokenizer 词表资源的更新检查。切回联网后，资源页面允许点重试，下载进度由系统任务报告。这里处理的是资源下载页。"),
        ("圆桌论坛接站备忘", "外地分享者搭高铁抵达白沙站。班次不准点时先给负责接站的阿岑发车次和预计到站时刻，等他回电确定碰头处，再从闸口出来。"),
        ("地图外部图层合并", "外部数据可能用 EPSG:3857 的米坐标。写成标准 GeoJSON 前要转换到 WGS 84，检查 CRS 声明是否与数据一致，不能只给原数字更换标签。"),
        ("冬季整理美术教室", "会结冰的那段时间，把开过封的水性颜料全部从铁皮储物柜搬进有暖气的小库房。户外柜只放刷子、空桶和包布。"),
        ("浏览器预览文件出包", "前端的样片如果 moov atom 在文件尾部，播放器必须先取到元数据才能跳转播放位置。交付时用 faststart 把这段元数据挪到容器开头。"),
        ("河岸展览嘉宾接送", "从外地坐轮渡来的艺术家请到橙色候船棚等车。船晚点先联系展览场地前台，他们会转告负责摆渡的司机。"),
        ("藏书集市入场提醒", "星期六在柳枝礼堂换书。带轮子的推车请从临河一侧的西门进入。那里有一段与门槛齐平的缓坡，进门以后一路平到登记台。"),
        ("面板动效快照的输入", "面板 fixture 显式注入 prefers-reduced-motion 值。分别给普通和静态模式造固定输入，避免测试读取系统用户设置后每台机器走不同分支。"),
        ("图书馆南门通行", "公共图书馆的南门已经更换为自动门。周六带婴儿车进馆请走南门无障碍通道。图书馆和礼堂分属两栋楼，从馆内无法进入礼堂。"),
        ("版画体验课名额交接", "临时不能来的人可以把参加资格让给另一位成人。开课前一天晚上六点以前，在报名群私信助教替换姓名，材料包随资格一并移交。"),
    ]
}

private final class WorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var vectorCalls = 0
    private var onMain = false
    private var loaded = false

    var calls: Int { lock.withLock { vectorCalls } }
    var usedMainThread: Bool { lock.withLock { onMain } }
    var modelAvailable: Bool { lock.withLock { loaded } }

    func record() {
        lock.withLock {
            vectorCalls += 1
            onMain = onMain || Thread.isMainThread
        }
    }

    func recordLoad(available: Bool) {
        lock.withLock {
            loaded = available
            onMain = onMain || Thread.isMainThread
        }
    }
}

private final class WorkLatch: Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)

    func pause() {
        started.signal()
        _ = resumed.wait(timeout: .now() + 5)
    }

    func waitForStart() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    func resume() { resumed.signal() }
}
