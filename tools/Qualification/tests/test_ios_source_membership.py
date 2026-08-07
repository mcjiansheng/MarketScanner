import json
import tempfile
import unittest
from pathlib import Path

from tools.Qualification.check_ios_source_membership import audit_project


BUILD_FILE_1 = "AA0000000000000000000001"
FILE_REF_1 = "AA0000000000000000000002"
GROUP = "AA0000000000000000000003"
SOURCES_PHASE = "AA0000000000000000000004"
TARGET = "AA0000000000000000000005"
BUILD_FILE_2 = "AA0000000000000000000006"
PACKAGE_REF = "AA0000000000000000000007"


def fixture_pbxproj(
    *,
    source_path="RTABMapApp/Feature.swift",
    build_files=(BUILD_FILE_1,),
    build_file_definitions=None,
    group_children=(FILE_REF_1,),
    include_file_ref=True,
    remote_package=False,
):
    if build_file_definitions is None:
        build_file_definitions = {BUILD_FILE_1: FILE_REF_1}
    build_objects = "\n".join(
        f"\t\t{identifier} /* Feature.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_ref} /* Feature.swift */; }};"
        for identifier, file_ref in build_file_definitions.items()
    )
    file_ref_object = ""
    if include_file_ref:
        file_ref_object = (
            f"\t\t{FILE_REF_1} /* Feature.swift */ = {{isa = PBXFileReference; "
            f"lastKnownFileType = sourcecode.swift; path = {source_path}; sourceTree = \"<group>\"; }};"
        )
    group_list = "\n".join(f"\t\t\t\t{identifier}," for identifier in group_children)
    phase_list = "\n".join(f"\t\t\t\t{identifier}," for identifier in build_files)
    package_object = ""
    if remote_package:
        package_object = (
            f"\t\t{PACKAGE_REF} /* Zip */ = {{\n"
            "\t\t\tisa = XCRemoteSwiftPackageReference;\n"
            "\t\t\trepositoryURL = \"https://github.com/marmelroy/Zip.git\";\n"
            "\t\t\trequirement = { kind = upToNextMajorVersion; minimumVersion = 2.1.0; };\n"
            "\t\t};"
        )
    return f"""// !$*UTF8*$!
{{
objects = {{
/* Begin PBXBuildFile section */
{build_objects}
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
{file_ref_object}
/* End PBXFileReference section */
/* Begin PBXGroup section */
\t\t{GROUP} /* Sources */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_list}
\t\t\t);
\t\t\tsourceTree = \"<group>\";
\t\t}};
/* End PBXGroup section */
/* Begin PBXFrameworksBuildPhase section */
/* End PBXFrameworksBuildPhase section */
/* Begin PBXResourcesBuildPhase section */
/* End PBXResourcesBuildPhase section */
/* Begin PBXNativeTarget section */
\t\t{TARGET} /* RTABMapApp */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildPhases = ({SOURCES_PHASE});
\t\t\tname = RTABMapApp;
\t\t}};
/* End PBXNativeTarget section */
/* Begin PBXSourcesBuildPhase section */
\t\t{SOURCES_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tfiles = (
{phase_list}
\t\t\t);
\t\t}};
/* End PBXSourcesBuildPhase section */
/* Begin XCRemoteSwiftPackageReference section */
{package_object}
/* End XCRemoteSwiftPackageReference section */
}};
}}
"""


class IOSSourceMembershipTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name)
        self.project = self.repo / "app/ios/RTABMapApp.xcodeproj/project.pbxproj"
        self.source_root = self.repo / "app/ios/RTABMapApp"
        self.project.parent.mkdir(parents=True)
        self.source_root.mkdir(parents=True)

    def write_source(self, relative="Feature.swift"):
        path = self.source_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("struct Feature {}\n", encoding="utf-8")

    def audit(self, pbxproj, *, check_package_lock=False, package_resolved=None):
        self.project.write_text(pbxproj, encoding="utf-8")
        return audit_project(
            repo=self.repo,
            project_path=self.project,
            source_root=self.source_root,
            check_package_lock=check_package_lock,
            package_resolved=package_resolved,
            legacy_exclusions=(),
        )

    def issue_codes(self, result):
        return {issue.code for issue in result.issues}

    def test_valid_target_membership_is_project_derived(self):
        self.write_source()
        result = self.audit(fixture_pbxproj())
        self.assertTrue(result.ok, result.issues)
        self.assertEqual([self.source_root / "Feature.swift"], result.swift_sources)

    def test_missing_production_source_is_rejected(self):
        self.write_source()
        result = self.audit(fixture_pbxproj(build_files=(), build_file_definitions={}))
        self.assertIn("production_source_missing", self.issue_codes(result))

    def test_duplicate_build_files_for_one_source_are_rejected(self):
        self.write_source()
        result = self.audit(
            fixture_pbxproj(
                build_files=(BUILD_FILE_1, BUILD_FILE_2),
                build_file_definitions={BUILD_FILE_1: FILE_REF_1, BUILD_FILE_2: FILE_REF_1},
            )
        )
        self.assertIn("duplicate_build_file", self.issue_codes(result))

    def test_stale_file_ref_is_rejected(self):
        result = self.audit(fixture_pbxproj())
        self.assertIn("stale_file_ref", self.issue_codes(result))

    def test_case_mismatch_is_rejected(self):
        self.write_source("Feature.swift")
        result = self.audit(fixture_pbxproj(source_path="RTABMapApp/feature.swift"))
        self.assertIn("case_mismatch", self.issue_codes(result))

    def test_orphan_file_ref_and_build_file_are_rejected(self):
        self.write_source()
        orphan_file_ref = self.audit(fixture_pbxproj(group_children=()))
        self.assertIn("orphan_file_ref", self.issue_codes(orphan_file_ref))

        orphan_build_file = self.audit(
            fixture_pbxproj(build_files=(), build_file_definitions={BUILD_FILE_1: FILE_REF_1})
        )
        self.assertIn("orphan_build_file", self.issue_codes(orphan_build_file))

    def test_test_source_cannot_enter_production_target(self):
        self.write_source("Tests/FeatureTests.swift")
        result = self.audit(fixture_pbxproj(source_path="RTABMapApp/Tests/FeatureTests.swift"))
        self.assertIn("test_source_in_production", self.issue_codes(result))

    def test_remote_package_requires_exact_shared_lock(self):
        self.write_source()
        lock = self.repo / "Package.resolved"
        missing = self.audit(
            fixture_pbxproj(remote_package=True),
            check_package_lock=True,
            package_resolved=lock,
        )
        self.assertIn("package_lock_missing", self.issue_codes(missing))

        lock.write_text(
            json.dumps(
                {
                    "pins": [
                        {
                            "identity": "zip",
                            "location": "https://github.com/marmelroy/Zip.git",
                            "state": {
                                "revision": "67fa55813b9e7b3b9acee9c0ae501def28746d76",
                                "version": "2.1.2",
                            },
                        }
                    ],
                    "version": 2,
                }
            ),
            encoding="utf-8",
        )
        locked = self.audit(
            fixture_pbxproj(remote_package=True),
            check_package_lock=True,
            package_resolved=lock,
        )
        self.assertTrue(locked.ok, locked.issues)

    def test_repository_project_contains_all_shipping_swift(self):
        repo = Path(__file__).resolve().parents[3]
        result = audit_project(
            repo=repo,
            project_path=repo / "app/ios/RTABMapApp.xcodeproj/project.pbxproj",
            source_root=repo / "app/ios/RTABMapApp",
            check_package_lock=False,
        )
        self.assertTrue(result.ok, result.issues)
        names = {path.name for path in result.swift_sources}
        self.assertTrue(
            {
                "GeneratedMobileEvidenceContracts.swift",
                "StrictJSONLStreamReader.swift",
                "TagObservationBurstEvidenceParser.swift",
                "StrictLocalizationTraceParser.swift",
                "TagObservationEvidenceParser.swift",
                "XLSXWorkbookVerifier.swift",
            }.issubset(names)
        )


if __name__ == "__main__":
    unittest.main()
