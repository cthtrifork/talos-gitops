import unittest

from check_manifest_filenames import check_kinds, filename_matches_kind


class ManifestFilenameTests(unittest.TestCase):
    def test_each_kind_has_its_own_filename(self):
        self.assertEqual(check_kinds("deployment.yaml", {"Deployment"}), [])
        self.assertEqual(
            check_kinds("deployment-service.yaml", {"Deployment", "Service"}),
            ["Deployment", "Service"],
        )

    def test_multiple_documents_of_the_same_kind_are_allowed(self):
        self.assertEqual(check_kinds("service.yaml", {"Service"}), [])

    def test_known_alias_is_accepted(self):
        self.assertTrue(filename_matches_kind("networkpolicy.yaml", "CiliumNetworkPolicy"))
        self.assertTrue(filename_matches_kind("pdb.yaml", "PodDisruptionBudget"))

    def test_selected_grouped_filename_is_accepted(self):
        self.assertEqual(
            check_kinds("rbac.yaml", {"ClusterRole", "ClusterRoleBinding"}), []
        )

    def test_application_name_alone_is_rejected(self):
        self.assertFalse(filename_matches_kind("urlshare.yaml", "Deployment"))

    def test_grouped_filename_does_not_allow_unlisted_kinds(self):
        self.assertEqual(
            check_kinds("rbac.yaml", {"ClusterRole", "Service"}),
            ["ClusterRole", "Service"],
        )


if __name__ == "__main__":
    unittest.main()
