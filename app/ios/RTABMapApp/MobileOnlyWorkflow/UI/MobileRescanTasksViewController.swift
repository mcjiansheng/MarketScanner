import UIKit

/// Rescan tasks screen (V1R1 Gate A / Gate I): shows the
/// RESCAN_REQUIRED tasks extracted from a result package so the operator
/// can re-scan the flagged tags.
final class MobileRescanTasksViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var resultEntry: MobileResultLibrary.ResultEntry?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var tasks: [[String: Any]] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "补扫任务"
        view.backgroundColor = .systemBackground

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        loadTasks()
    }

    private func loadTasks() {
        guard let entry = resultEntry else { return }
        let url = entry.directory.appendingPathComponent("rescan_tasks.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? StrictJSONDocumentParser.object(
                  from: data,
                  limits: StrictJSONDocumentLimits(maximumBytes: data.count + 1)) as? [String: Any],
              let raw = object["tasks"] as? [[String: Any]]
        else { return }
        tasks = raw
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(tasks.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        if tasks.isEmpty {
            cell.textLabel?.text = "没有补扫任务"
            cell.textLabel?.textColor = .secondaryLabel
            cell.detailTextLabel?.text = nil
            return cell
        }
        let task = tasks[indexPath.row]
        cell.textLabel?.text = "\(task["barcode"] as? String ?? "") @ \(task["shelf_code"] as? String ?? "")"
        cell.textLabel?.textColor = .label
        cell.detailTextLabel?.text = task["reason_code"] as? String ?? ""
        return cell
    }
}
