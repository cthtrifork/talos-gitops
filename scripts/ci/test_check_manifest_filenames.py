import unittest

from check_manifest_filenames import filename_matches_kind


class FilenameMatchesKindTests(unittest.TestCase):
    def test_kind_name_may_be_combined_with_other_kinds(self):
        self.assertTrue(filename_matches_kind("deployment-service.yaml", "Deployment"))
        self.assertTrue(filename_matches_kind("deployment-service.yaml", "Service"))

    def test_known_alias_is_accepted(self):
        self.assertTrue(filename_matches_kind("networkpolicy.yaml", "CiliumNetworkPolicy"))
        self.assertTrue(filename_matches_kind("pdb.yaml", "PodDisruptionBudget"))

    def test_selected_grouped_filename_is_accepted(self):
        self.assertTrue(filename_matches_kind("rbac.yaml", "ClusterRoleBinding"))

    def test_application_name_alone_is_rejected(self):
        self.assertFalse(filename_matches_kind("urlshare.yaml", "Deployment"))

    def test_grouped_filename_does_not_allow_unlisted_kinds(self):
        self.assertFalse(filename_matches_kind("rbac.yaml", "ConfigMap"))


if __name__ == "__main__":
    unittest.main()
