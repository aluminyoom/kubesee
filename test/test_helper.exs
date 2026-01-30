ExUnit.start()

Mox.defmock(Kubesee.K8sClientMock, for: Kubesee.K8sClient)
Mox.defmock(Kubesee.K8sClientMockImpl, for: Kubesee.K8sClientImpl.Behaviour)
Mox.defmock(Kubesee.FileImpl, for: Kubesee.FileImpl.Behaviour)
Mox.defmock(Kubesee.EnvImpl, for: Kubesee.EnvImpl.Behaviour)
Mox.defmock(Kubesee.K8sConnImpl, for: Kubesee.K8sConnImpl.Behaviour)
Mox.defmock(Kubesee.K8sConnMock, for: Kubesee.K8sConnBehaviour)

System.put_env("KUBESEE_CONFIG", "/tmp/kubesee_dummy_test.yaml")
Application.put_env(:kubesee, :k8s_conn, Kubesee.K8sConnMock)
